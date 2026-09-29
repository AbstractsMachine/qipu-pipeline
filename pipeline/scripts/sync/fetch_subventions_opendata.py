#!/usr/bin/env python3
"""
Fetch subventions data from OpenData Paris API → produit le snapshot
pré-enrichissement consommé par les scripts d'enrichissement LLM.

Hits two datasets via the bulk `/exports/json` endpoint, merges them, and
writes one beneficiaires_<year>.json per year + index/treemap into the
INTERNAL cache directory `pipeline/cache/subventions_pre_enrichment/`.

Cette sortie n'est PAS publiée — elle alimente les scripts
`enrich_*_llm.py` et `enrich_sirene.py` qui produisent à leur tour les
seeds `seed_cache_*.csv` consommés par dbt. La sortie publique
`website/public/data/subventions/*.json` est produite par
`pipeline/scripts/export/export_subventions_data.py` à partir des marts.

Sources:
    1. subventions-associations-votees-                   (rich: siret, direction,
                                                           objet, secteurs — associations only)
    2. subventions-versees-annexe-compte-administratif-a-partir-de-2018
                                                          (broader: all beneficiaires,
                                                           minimal fields)

When the same (year, normalized_name) appears in both, fields from the rich
dataset win. Amounts are summed from the rich dataset (deterministic, matches
the Conseil de Paris votes); the annexe CA only fills in beneficiaires missing
from the votées dataset (public establishments, foundations, companies, etc.).

Usage:
    python pipeline/scripts/sync/fetch_subventions_opendata.py
    python pipeline/scripts/sync/fetch_subventions_opendata.py --year 2023 --dry-run
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import requests

ROOT = Path(__file__).resolve().parents[3]
# Sortie interne (cache) — pas publiée. Consommée par les scripts d'enrich.
OUTPUT = ROOT / "pipeline" / "cache" / "subventions_pre_enrichment"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _paris_portal  # noqa: E402
OPENDATA_API = _paris_portal.api("/catalog/datasets")
DATASET_VOTEES = "subventions-associations-votees-"
DATASET_ANNEXE_CA = "subventions-versees-annexe-compte-administratif-a-partir-de-2018"

SESSION = requests.Session()
SESSION.headers.update({"User-Agent": "Qipu-Fetcher/1.0 (+contact@qipu.org)"})


# ─────────────────────────────────────────────────────────────────────────
# Utils
# ─────────────────────────────────────────────────────────────────────────


def normalize_name(name: str) -> str:
    """Uppercase, strip diacritics, collapse non-alphanumeric to single spaces."""
    if not name:
        return ""
    s = unicodedata.normalize("NFD", name)
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    s = s.upper()
    s = re.sub(r"[^A-Z0-9]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def parse_year(raw: Any) -> int | None:
    if raw is None:
        return None
    m = re.search(r"(\d{4})", str(raw))
    if not m:
        return None
    y = int(m.group(1))
    return y if 2010 <= y <= 2030 else None


def fetch_all(dataset_id: str) -> list[dict]:
    """Bulk-fetch every record from a dataset via /exports/json."""
    url = f"{OPENDATA_API}/{dataset_id}/exports/json"
    params = {"lang": "fr", "timezone": "Europe/Paris"}
    print(f"  → GET {url}", flush=True)
    r = SESSION.get(url, params=params, timeout=300)
    r.raise_for_status()
    data = r.json()
    print(f"     {len(data):,} records", flush=True)
    return data


# ─────────────────────────────────────────────────────────────────────────
# Aggregation
# ─────────────────────────────────────────────────────────────────────────


@dataclass
class Bucket:
    display_names: dict[str, int] = field(default_factory=dict)  # name → count
    montant_total: float = 0.0
    nb_subventions: int = 0
    nature_juridique: str | None = None
    categorie: str | None = None
    direction: str | None = None
    siret: str | None = None
    objets: dict[str, int] = field(default_factory=dict)
    secteurs: set[str] = field(default_factory=set)
    source: str = "votees"  # or "annexe_ca"

    def add_display(self, name: str) -> None:
        if not name:
            return
        self.display_names[name] = self.display_names.get(name, 0) + 1

    def add_objet(self, objet: str | None) -> None:
        if not objet:
            return
        self.objets[objet] = self.objets.get(objet, 0) + 1

    def pick_display(self) -> str:
        if not self.display_names:
            return ""
        # Most frequent; tie-break = longest (usually the fullest spelling)
        return max(self.display_names.items(), key=lambda kv: (kv[1], len(kv[0])))[0]

    def pick_objet(self) -> str | None:
        if not self.objets:
            return None
        return max(self.objets.items(), key=lambda kv: kv[1])[0]


def aggregate_votees(records: list[dict]) -> dict[tuple[int, str], Bucket]:
    agg: dict[tuple[int, str], Bucket] = defaultdict(Bucket)
    for r in records:
        year = parse_year(r.get("annee_budgetaire"))
        name = (r.get("nom_beneficiaire") or "").strip()
        if not (year and name):
            continue
        key = (year, normalize_name(name))
        b = agg[key]
        b.add_display(name)
        b.montant_total += float(r.get("montant_vote") or 0)
        b.nb_subventions += 1
        b.nature_juridique = b.nature_juridique or "Associations"
        b.categorie = b.categorie or "Personnes de droit privé"
        b.direction = b.direction or r.get("direction")
        siret = r.get("numero_siret")
        if siret and not b.siret:
            b.siret = str(siret).strip() or None
        b.add_objet(r.get("objet_du_dossier"))
        secteurs = r.get("secteurs_d_activites_definies_par_l_association") or []
        if isinstance(secteurs, list):
            b.secteurs.update(s for s in secteurs if s)
        elif isinstance(secteurs, str) and secteurs:
            b.secteurs.add(secteurs)
        b.source = "votees"
    return agg


def aggregate_annexe_ca(records: list[dict]) -> dict[tuple[int, str], Bucket]:
    agg: dict[tuple[int, str], Bucket] = defaultdict(Bucket)
    for r in records:
        year = parse_year(r.get("publication"))
        name = (r.get("nom_de_l_organisme_beneficiaire") or "").strip()
        if not (year and name):
            continue
        key = (year, normalize_name(name))
        b = agg[key]
        b.add_display(name)
        # Include prestations en nature as in-kind; montant = numeraire part only
        b.montant_total += float(r.get("montant_de_la_subvention") or 0)
        b.nb_subventions += 1
        b.nature_juridique = b.nature_juridique or r.get("nature_juridique_du_beneficiaire")
        b.categorie = b.categorie or r.get("categorie_du_beneficiaire")
        b.source = "annexe_ca"
    return agg


def merge(
    primary: dict[tuple[int, str], Bucket],
    supplement: dict[tuple[int, str], Bucket],
) -> dict[tuple[int, str], Bucket]:
    """Primary wins on shared keys; supplement fills in missing keys."""
    out: dict[tuple[int, str], Bucket] = dict(primary)
    for key, b in supplement.items():
        if key not in out:
            out[key] = b
    return out


# ─────────────────────────────────────────────────────────────────────────
# Output
# ─────────────────────────────────────────────────────────────────────────


def bucket_to_row(year: int, norm: str, b: Bucket) -> dict:
    return {
        "annee": year,
        "beneficiaire": b.pick_display(),
        "beneficiaire_normalise": norm,
        "nature_juridique": b.nature_juridique,
        "direction": b.direction,
        "secteurs_activite": " | ".join(sorted(b.secteurs)) if b.secteurs else None,
        "thematique": None,          # filled downstream by dbt/LLM enrichment
        "sous_categorie": None,
        "source_thematique": None,
        "montant_total": round(b.montant_total, 2),
        "nb_subventions": b.nb_subventions,
        "objet_principal": b.pick_objet(),
        "siret": b.siret,
    }


def write_beneficiaires_year(year: int, rows: list[dict], dry_run: bool) -> Path:
    rows_sorted = sorted(rows, key=lambda r: -r["montant_total"])
    payload = {
        "year": year,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "total_montant": round(sum(r["montant_total"] for r in rows_sorted), 2),
        "nb_beneficiaires": len(rows_sorted),
        "data": rows_sorted,
    }
    path = OUTPUT / f"beneficiaires_{year}.json"
    if dry_run:
        print(f"  [dry-run] would write {path}  ({len(rows_sorted):,} rows)")
        return path
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2))
    print(f"  wrote {path}  ({len(rows_sorted):,} rows, {payload['total_montant']:,.0f} €)")
    return path


def write_treemap_year(year: int, rows: list[dict], dry_run: bool) -> Path:
    """Aggregate rows by theme/categorie (fallback to nature_juridique since theme
    is filled later). Keeps the pre-existing treemap schema."""
    agg: dict[str, dict[str, Any]] = defaultdict(lambda: {
        "nb_beneficiaires": 0,
        "nb_subventions": 0,
        "montant_total": 0.0,
    })
    for r in rows:
        # Fallback cascade for the treemap label
        label = r.get("thematique") or r.get("nature_juridique") or "Autre"
        a = agg[label]
        a["nb_beneficiaires"] += 1
        a["nb_subventions"] += r["nb_subventions"]
        a["montant_total"] += r["montant_total"]
    total = sum(a["montant_total"] for a in agg.values()) or 1
    data = []
    for thematique, a in agg.items():
        data.append({
            "annee": year,
            "thematique": thematique,
            "nb_beneficiaires": a["nb_beneficiaires"],
            "nb_subventions": a["nb_subventions"],
            "montant_total": round(a["montant_total"], 2),
            "pct_total": round(a["montant_total"] / total * 100, 2),
        })
    data.sort(key=lambda d: -d["montant_total"])
    payload = {
        "year": year,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "data": data,
    }
    path = OUTPUT / f"treemap_{year}.json"
    if dry_run:
        print(f"  [dry-run] would write {path}  ({len(data)} themes)")
        return path
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2))
    print(f"  wrote {path}  ({len(data)} themes)")
    return path


def write_index(years: list[int], dry_run: bool, totals_by_year: dict[int, dict] | None = None) -> Path:
    """Réécrit index.json en mergeant les années nouvelles avec les
    existantes et en auto-détectant les années 'preview' (volume très
    inférieur à la médiane → données partielles, ex. 2020/2021 dans la
    source OpenData)."""
    path = OUTPUT / "index.json"
    existing: dict = {}
    if path.exists():
        try:
            existing = json.loads(path.read_text())
        except Exception:
            pass

    # Merge des années (ne pas écraser celles déjà connues)
    prev_years = set(existing.get("availableYears", []))
    merged_years = sorted(prev_years | set(years), reverse=True)
    existing["availableYears"] = merged_years

    # Merge totalsByYear
    totals = dict(existing.get("totalsByYear", {}))
    if totals_by_year:
        for y, t in totals_by_year.items():
            totals[str(y)] = t
    existing["totalsByYear"] = totals

    # Auto-détection des années 'preview' : montant_total < 50 % de la
    # médiane des autres années. Plus robuste que `nb_subventions` qui peut
    # rester gonflé si le dataset 'votées' contient des annee_budgetaire
    # historiques pour une année où la donnée Annexe CA est incomplète
    # (ex: 2020/2021 où il manque les grosses subventions aux EPL).
    montants_per_year: list[tuple[int, float]] = []
    for y_str, t in totals.items():
        m = (t or {}).get("montant_total") or 0
        if m > 0:
            montants_per_year.append((int(y_str), m))
    if len(montants_per_year) >= 3:
        sorted_m = sorted(m for _, m in montants_per_year)
        median_m = sorted_m[len(sorted_m) // 2]
        threshold = median_m * 0.5
        preview = sorted(
            {y for y, m in montants_per_year if m < threshold}, reverse=True,
        )
        if preview:
            existing["previewYears"] = preview
            print(
                f"  → previewYears auto-détectés "
                f"(montant_total < 50% médiane {median_m/1e6:.0f} M€) : {preview}"
            )
        else:
            existing.pop("previewYears", None)

    existing["generated_at"] = datetime.now(timezone.utc).isoformat()
    if dry_run:
        print(f"  [dry-run] would write {path} with years={merged_years}")
        return path
    path.write_text(json.dumps(existing, ensure_ascii=False, indent=2))
    print(f"  wrote {path}  (years={merged_years})")
    return path


# ─────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--year", type=int, help="Restrict output to a single year (for testing)")
    ap.add_argument("--min-year", type=int, default=2018,
                    help="Lower bound (inclusive). Default 2018 to avoid breaking the frontend")
    ap.add_argument("--max-year", type=int, default=2024,
                    help="Upper bound (inclusive). Default 2024; 2025 is preserved via scrape")
    ap.add_argument("--skip-annexe", action="store_true",
                    help="Only use the associations-votées dataset (skip Annexe CA)")
    ap.add_argument("--dry-run", action="store_true",
                    help="Fetch + aggregate but do not write files")
    ap.add_argument("--keep-2025", action="store_true",
                    help="Also overwrite beneficiaires_2025.json (default: preserved "
                         "— the deliberation-scrape output is kept)")
    args = ap.parse_args()

    OUTPUT.mkdir(parents=True, exist_ok=True)

    print(f"[1/3] fetch {DATASET_VOTEES}")
    votees = fetch_all(DATASET_VOTEES)
    primary = aggregate_votees(votees)

    if args.skip_annexe:
        merged = primary
    else:
        print(f"[2/3] fetch {DATASET_ANNEXE_CA}")
        annexe = fetch_all(DATASET_ANNEXE_CA)
        supplement = aggregate_annexe_ca(annexe)
        merged = merge(primary, supplement)

    # Split by year
    by_year: dict[int, list[dict]] = defaultdict(list)
    for (year, norm), b in merged.items():
        if args.year and year != args.year:
            continue
        if not args.year:
            if year < args.min_year or year > args.max_year:
                continue
        if year == 2025 and not args.keep_2025:
            continue
        by_year[year].append(bucket_to_row(year, norm, b))

    print(f"[3/3] write {len(by_year)} year files to {OUTPUT}")
    years_written: list[int] = []
    totals_by_year: dict[int, dict] = {}
    for year in sorted(by_year):
        rows = by_year[year]
        write_beneficiaires_year(year, rows, args.dry_run)
        write_treemap_year(year, rows, args.dry_run)
        years_written.append(year)
        totals_by_year[year] = {
            "montant_total": sum(r["montant_total"] for r in rows),
            "nb_subventions": sum(r["nb_subventions"] for r in rows),
        }

    # Merge years list with existing (keep 2025 if it exists and we're not overwriting)
    if (OUTPUT / "beneficiaires_2025.json").exists():
        years_written.append(2025)

    write_index(years_written, args.dry_run, totals_by_year=totals_by_year)

    print("\nSUMMARY")
    for year in sorted(by_year):
        rows = by_year[year]
        total = sum(r["montant_total"] for r in rows)
        print(f"  {year}: {len(rows):,} bénéficiaires — {total:,.0f} €")

    return 0


if __name__ == "__main__":
    sys.exit(main())
