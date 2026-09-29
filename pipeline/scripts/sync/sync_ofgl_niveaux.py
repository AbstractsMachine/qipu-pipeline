#!/usr/bin/env python3
"""
OFGL consolidée des régions, des départements et des intercommunalités →
raw_national.ofgl_regions / ofgl_departements / ofgl_gfp (BigQuery).

Pourquoi (2026-09-26). L'échelle des niveaux (France → région → département →
intercommunalité → commune) donne à chaque collectivité au-dessus de la commune
sa propre page, avec les mêmes repères que la page d'une commune. L'OFGL publie
ces comptes au même grain que ceux des communes (collectivité × exercice ×
agrégat), sous la même licence, chaque été :

  ofgl-base-regions-consolidee       2012-2025, 17 collectivités depuis 2016
                                     (14 régions + Corse, Martinique, Guyane)
  ofgl-base-departements-consolidee  2012-2025, 97 en 2025 (dont la Métropole
                                     de Lyon et Paris)
  ofgl-base-gfp-consolidee           2018-2025, ~1 217 intercommunalités à
                                     fiscalité propre (CC, CA, CU, métropoles, EPT)

Même méthode que sync_ofgl_national.py (les communes) : tous les agrégats, une
année à la fois par _national_raw.replace_year, le nombre de lignes de
l'export contrôlé contre celui qu'annonce l'API, seules les années absentes ou
différentes rechargées, et NATIONAL_CHECK_ONLY=1 pour la veille du mardi.

Les colonnes sont celles de chaque base, telles quelles (le staging les
rassemble) : les trois ne portent pas les mêmes (le type d'intercommunalité
n'existe que pour les GFP, le statut urbain/rural que pour les départements).

Usage:
    python scripts/sync/sync_ofgl_niveaux.py                      # les trois niveaux
    python scripts/sync/sync_ofgl_niveaux.py --niveaux departements
    python scripts/sync/sync_ofgl_niveaux.py --dry-run
    python scripts/sync/sync_ofgl_niveaux.py --niveaux gfp --years 2025
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from urllib.parse import urlencode

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _national_raw as NR  # noqa: E402

API = "https://data.ofgl.fr/api/explore/v2.1/catalog/datasets/"
YEAR_COL = "exer"
MAX_ATTEMPTS = 5
LOAD_ARGS = ("--source_format=CSV", "--skip_leading_rows=1", "--field_delimiter=;")
ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = ROOT / "cache" / "wip" / "national" / "ofgl-niveaux"

_COMMUNS = [
    ("exer", "INTEGER"), ("siren", "STRING"), ("categ", "STRING"), ("lbudg", "STRING"),
    ("outre_mer", "STRING"), ("reg_code", "STRING"), ("reg_name", "STRING"),
]
_MONTANTS = [
    ("agregat", "STRING"), ("montant", "FLOAT"), ("montant_bp", "FLOAT"), ("montant_ba", "FLOAT"),
    ("montant_flux", "FLOAT"), ("ptot", "FLOAT"), ("euros_par_habitant", "FLOAT"),
]

NIVEAUX: dict[str, dict] = {
    "regions": {
        "dataset": "ofgl-base-regions-consolidee",
        "table": "ofgl_regions",
        "first_year": 2012,
        "cols": _COMMUNS + [("reg_is_ctu", "STRING")] + _MONTANTS,
    },
    "departements": {
        "dataset": "ofgl-base-departements-consolidee",
        "table": "ofgl_departements",
        "first_year": 2012,
        "cols": _COMMUNS + [
            ("dep_code", "STRING"), ("dep_name", "STRING"),
            ("dep_tranche_population", "STRING"), ("dep_status", "STRING"),
        ] + _MONTANTS,
    },
    "gfp": {
        "dataset": "ofgl-base-gfp-consolidee",
        "table": "ofgl_gfp",
        "first_year": 2018,
        "cols": _COMMUNS + [
            ("dep_code", "STRING"), ("dep_name", "STRING"),
            ("epci_code", "STRING"), ("epci_name", "STRING"),
            ("nat_juridique", "STRING"), ("gfp_tranche_population", "STRING"),
            ("mode_financement", "STRING"),
        ] + _MONTANTS,
    },
}

WHERE = "agregat IS NOT NULL"


def published_counts(dataset: str) -> dict[int, int]:
    """Lignes publiées par exercice (même filtre que le chargement)."""
    url = API + dataset + "/records?" + urlencode(
        {"select": "exer, count(*) as n", "where": WHERE, "group_by": "exer", "limit": 100}
    )
    r = requests.get(url, timeout=120)
    r.raise_for_status()
    return {int(str(x["exer"])[:4]): int(x["n"]) for x in r.json().get("results", []) if x.get("exer")}


def download_year(niv: str, cfg: dict, year: int) -> tuple[Path, int]:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    out = CACHE_DIR / f"{niv}_{year}.csv"
    select = ",".join(c for c, _ in cfg["cols"])
    url = API + cfg["dataset"] + "/exports/csv?" + urlencode(
        {"where": f"year(exer)={year} AND {WHERE}", "select": select, "delimiter": ";", "use_labels": "false"}
    )
    n_lines = 0
    with requests.get(url, stream=True, timeout=900) as resp:
        resp.raise_for_status()
        with open(out, "wb") as f:
            for chunk in resp.iter_content(chunk_size=1 << 20):
                if chunk:
                    f.write(chunk)
                    n_lines += chunk.count(b"\n")
    return out, max(n_lines - 1, 0)


def sync_year(niv: str, cfg: dict, year: int, expected: int, force: bool) -> None:
    for attempt in range(1, MAX_ATTEMPTS + 1):
        path, rows = download_year(niv, cfg, year)
        if rows == expected:
            break
        print(f"  [{niv} {year}] tentative {attempt} : {rows:,} lignes pour {expected:,} annoncées — export tronqué, on recommence")
    else:
        raise NR.GuardError(f"✗ [{niv} {year}] export toujours incomplet après {MAX_ATTEMPTS} tentatives — table inchangée")
    schema = ",".join(f"{c}:{t}" for c, t in cfg["cols"])
    NR.replace_year(cfg["table"], YEAR_COL, year, path, schema, expected_rows=expected, load_args=LOAD_ARGS, force=force)


def sync_niveau(niv: str, years: list[int] | None, dry_run: bool, force: bool) -> None:
    cfg = NIVEAUX[niv]
    table = cfg["table"]
    have = NR.rows_by_year(table, YEAR_COL)
    published = published_counts(cfg["dataset"])
    todo_years = years or sorted(y for y in published if y >= cfg["first_year"])
    print(f"→ {cfg['dataset']} → {NR.DATASET_ID}.{table} — publiées {sorted(published)}, en table {sorted(have)}")
    todo = []
    for y in todo_years:
        exp, cur = published.get(y, 0), have.get(y, 0)
        if exp and (years or cur != exp):
            print(f"  [{y}] publié {exp:,} lignes — {'absente' if not cur else f'{cur:,} en table'}")
            todo.append((y, exp))
    if not todo:
        print("  = à jour")
        return
    if dry_run or NR.CHECK_ONLY:
        for y, exp in todo:
            if NR.CHECK_ONLY:
                NR.would_change(table, f"{y} : {have.get(y, 0):,} → {exp:,} lignes")
        print(f"  (dry-run) à charger : {[y for y, _ in todo]}")
        return
    for y, exp in todo:
        sync_year(niv, cfg, y, exp, force)
    print(f"✓ {NR.DATASET_ID}.{table} : {len(todo)} année(s) chargée(s)")


def main() -> int:
    ap = argparse.ArgumentParser(description="OFGL consolidée des régions, départements et intercommunalités → raw_national")
    ap.add_argument("--niveaux", nargs="+", choices=sorted(NIVEAUX), default=list(NIVEAUX))
    ap.add_argument("--years", type=int, nargs="+", help="recharger ces années (sinon : absentes ou changées)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true", help="accepter une baisse de volume sur une année")
    args = ap.parse_args()
    for niv in args.niveaux:
        sync_niveau(niv, args.years, args.dry_run, args.force)
    return 0


if __name__ == "__main__":
    sys.exit(main())
