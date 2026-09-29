#!/usr/bin/env python3
"""
National ingest — Fonds vert (projets subventionnés par l'État, 2023-2025)
→ raw_national.fonds_vert (BigQuery).

Source : ministère de la Transition écologique, data.gouv.fr, licence ouverte.
Trois fichiers annuels aux colonnes différentes, ramenés à un même schéma :
  2023 : nom_beneficiaire_principal + siren, pas de résumé
  2024, 2025 : siret_beneficiaire, raison sociale, forme juridique, résumé
Les fichiers « p113 » (opérateurs, sans commune ni SIRET) ne sont pas chargés.

Mise à jour automatique (2026-09-14) : la date de dernière modification de
chaque fichier annuel est rangée dans la description de la table ; seules les
années dont le fichier a changé (ou qui manquent) sont rechargées, une par une,
par _national_raw.replace_year. Avant, chaque passage remplaçait la table.

Usage :
    python scripts/sync/sync_fonds_vert.py              # années nouvelles ou modifiées
    python scripts/sync/sync_fonds_vert.py --dry-run    # dit ce qui serait chargé
    python scripts/sync/sync_fonds_vert.py --force      # recharge tout, accepte une baisse
"""
from __future__ import annotations

import csv
import io
import json
import re
import subprocess
import sys
import urllib.request
import argparse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _national_raw as NR  # noqa: E402

PROJECT_ID = "open-data-france-484717"
DATASET_ID = "raw_national"
TABLE = "fonds_vert"
DATASET_API = "https://www.data.gouv.fr/api/1/datasets/fonds-vert-liste-des-projets-subventionnes/"
COLS = ["annee", "nom_projet", "resume_projet", "montant_engage", "demarche", "siren_beneficiaire",
        "raison_sociale_beneficiaire", "forme_juridique_beneficiaire", "code_commune", "nom_commune",
        "code_departement", "nom_departement", "nom_region", "numero_dossier"]
BQ_SCHEMA = ",".join(f"{c}:{'INTEGER' if c == 'annee' else 'FLOAT' if c == 'montant_engage' else 'STRING'}" for c in COLS)
ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = ROOT / "cache" / "wip" / "national" / "fonds_vert"


def money(x: str | None) -> float | None:
    if not x:
        return None
    t = re.sub(r"[^\d,.-]", "", x).replace(",", ".")
    try:
        return float(t)
    except ValueError:
        return None


def norm(row: dict, year: int) -> dict | None:
    g = lambda *ks: next(((row.get(k) or "").strip() for k in ks if row.get(k)), "")  # noqa: E731
    siren = g("siren") or g("siret_beneficiaire")[:9]
    code_commune = g("code_commune")
    if not (siren or code_commune):
        return None
    return {
        "annee": year,
        "nom_projet": g("nom_du_projet"),
        "resume_projet": g("resume_du_projet"),
        "montant_engage": money(g("montant_engage")),
        "demarche": g("demarche") or g("nom_demarche_ds"),
        "siren_beneficiaire": siren if re.fullmatch(r"\d{9}", siren) else "",
        "raison_sociale_beneficiaire": g("raison_sociale_beneficiaire") or g("nom_beneficiaire_principal"),
        "forme_juridique_beneficiaire": g("forme_juridique_beneficiaire", "forme juridique_beneficiaire"),
        "code_commune": code_commune,
        "nom_commune": g("nom_commune"),
        "code_departement": g("code_departement"),
        "nom_departement": g("nom_departement"),
        "nom_region": g("nom_region"),
        "numero_dossier": g("numero_dossier_ds"),
    }


YEAR_COL = "annee"


def year_resources() -> dict[int, dict]:
    with urllib.request.urlopen(DATASET_API, timeout=60) as r:
        d = json.load(r)
    out = {}
    for res in d["resources"]:
        m = re.match(r"fonds-vert-(\d{4})-export\.csv$", res.get("title") or "")
        if res.get("format") == "csv" and m:  # p113 et xlsx ignorés
            out[int(m.group(1))] = {"url": res["url"], "last_modified": res.get("last_modified")}
    return out


def build_year_csv(year: int, res: dict) -> tuple[Path, int]:
    raw = urllib.request.urlopen(res["url"], timeout=300).read().decode("utf-8-sig", errors="replace")
    dl = ";" if raw[:400].count(";") > raw[:400].count(",") else ","
    out = CACHE_DIR / f"fonds_vert_{year}.csv"
    k = 0
    with open(out, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS)
        w.writeheader()
        for row in csv.DictReader(io.StringIO(raw), delimiter=dl):
            r2 = norm(row, year)
            if r2:
                w.writerow(r2)
                k += 1
    print(f"  [{year}] {k:,} projets → {out.name}")
    return out, k


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    resources = year_resources()
    have = NR.rows_by_year(TABLE, YEAR_COL)
    m = NR.meta(TABLE)
    seen = m.get("annees", {})
    todo = [y for y, res in sorted(resources.items())
            if args.force or y not in have or seen.get(str(y)) != res["last_modified"]]
    print(f"→ Fonds vert → {NR.DATASET_ID}.{TABLE} — fichiers {sorted(resources)}, en table {sorted(have)}, à charger {todo}")
    if not todo:
        print("  = rien à faire")
        return 0
    if args.dry_run or NR.CHECK_ONLY:
        for y in todo if NR.CHECK_ONLY else []:
            NR.would_change(TABLE, f"{y} : fichier du {resources[y]['last_modified']}")
        return 0
    for year in todo:
        path, rows = build_year_csv(year, resources[year])
        NR.replace_year(TABLE, YEAR_COL, year, path, BQ_SCHEMA, expected_rows=rows,
                        load_args=("--source_format=CSV", "--skip_leading_rows=1", "--allow_quoted_newlines"), force=args.force)
        seen[str(year)] = resources[year]["last_modified"]
        NR.set_meta(TABLE, {**NR.meta(TABLE), "annees": seen})
    return 0


if __name__ == "__main__":
    sys.exit(main())
