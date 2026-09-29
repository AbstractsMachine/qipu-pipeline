#!/usr/bin/env python3
"""
National ingest — DGFiP Balances Comptables → raw_national.dgfip_balances (BigQuery).

Source: data.economie.gouv.fr, ODS Explore v2.1, one dataset per year
        `balances-comptables-des-communes-en-<YEAR>`.
Grain : commune × budget (cbudg) × compte (article) × year.

Strategy (national-first, NOT gated by any commune seed):
    Download the FULL year via the /exports/csv streaming endpoint, filtered
    SERVER-SIDE to the *budget principal* of *communes* only
    (`cbudg="1" AND categ="Commune"`), keeping only the 9 columns the budget
    models need. ~6.1M rows/year → ~250 MB CSV. Both M14 and M57 kept.

Mise à jour automatique (2026-09-14) :
    Par défaut, le script lit dans le catalogue les années publiées, compare
    pour chacune le nombre de lignes annoncé par le serveur à celui de la table,
    et ne recharge que les années absentes ou différentes, une par une, par
    _national_raw.replace_year (table temporaire, compte exact, garde de volume,
    transaction). Avant, il remplaçait la table sur sa première année et figeait
    [2024, 2023] : relancé tel quel, il effaçait 2019-2022, et les balances 2025
    publiées par la DGFiP n'ont jamais été chargées.

    L'export CSV s'arrête parfois en route sans erreur (2023 : 2,6 M lignes pour
    6,1 M annoncées, le 2026-09-09) : chaque année est retéléchargée jusqu'à
    MAX_ATTEMPTS fois tant que le compte n'est pas exact.

Usage:
    python scripts/sync/sync_dgfip_balances_national.py               # années manquantes ou changées
    python scripts/sync/sync_dgfip_balances_national.py --dry-run     # dit ce qui serait chargé, ne télécharge rien
    python scripts/sync/sync_dgfip_balances_national.py --years 2023  # recharge ces années (gardes actives)

Output:
    BigQuery table open-data-france-484717.raw_national.dgfip_balances
"""

import argparse
import re
import sys
from pathlib import Path
from urllib.parse import urlencode

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _national_raw as NR  # noqa: E402

TABLE = "dgfip_balances"
YEAR_COL = "exer"

DGFIP_EXPORT = (
    "https://data.economie.gouv.fr/api/explore/v2.1/catalog/datasets/"
    "balances-comptables-des-communes-en-{year}/exports/csv"
)
DGFIP_RECORDS = (
    "https://data.economie.gouv.fr/api/explore/v2.1/catalog/datasets/"
    "balances-comptables-des-communes-en-{year}/records"
)

# Columns kept (machine names). compte/siren stay STRING; amounts FLOAT64.
SELECT = "exer,siren,nomen,compte,cbudg,obnetdeb,obnetcre,sd,sc"
WHERE = 'cbudg="1" AND categ="Commune"'

# Explicit BQ schema — never let autodetect turn siren/compte into INT64.
BQ_SCHEMA = (
    "exer:INTEGER,siren:STRING,nomen:STRING,compte:STRING,cbudg:STRING,"
    "obnetdeb:FLOAT,obnetcre:FLOAT,sd:FLOAT,sc:FLOAT"
)

ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = ROOT / "cache" / "wip" / "national" / "dgfip"

CATALOG = "https://data.economie.gouv.fr/api/explore/v2.1/catalog/datasets"
DATASET_RE = re.compile(r"balances-comptables-des-communes-en-(\d{4})")
# Première année du socle national : sert quand la table n'existe pas encore.
FIRST_YEAR = 2019
MAX_ATTEMPTS = 5
LOAD_ARGS = ("--source_format=CSV", "--skip_leading_rows=1", "--field_delimiter=;")


def expected_count(year: int) -> int:
    """Server-side total_count for the filtered slice (no silent truncation check)."""
    url = DGFIP_RECORDS.format(year=year) + "?" + urlencode(
        {"where": WHERE, "limit": 0}
    )
    r = requests.get(url, timeout=60)
    r.raise_for_status()
    return int(r.json().get("total_count", 0))


def download_year(year: int) -> tuple[Path, int]:
    """Stream the filtered CSV export to disk. Returns (path, data_row_count)."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    out = CACHE_DIR / f"balances_{year}.csv"
    url = DGFIP_EXPORT.format(year=year) + "?" + urlencode(
        {"where": WHERE, "select": SELECT, "delimiter": ";", "use_labels": "false"}
    )
    print(f"  [{year}] streaming export → {out.name}")
    n_lines = 0
    with requests.get(url, stream=True, timeout=1800) as resp:
        resp.raise_for_status()
        with open(out, "wb") as f:
            for chunk in resp.iter_content(chunk_size=1 << 20):
                if chunk:
                    f.write(chunk)
                    n_lines += chunk.count(b"\n")
    data_rows = max(n_lines - 1, 0)  # minus header
    size_mb = out.stat().st_size / 1024 / 1024
    print(f"  [{year}] wrote {size_mb:.0f} MB, ~{data_rows:,} data rows")
    return out, data_rows


def available_years() -> list[int]:
    """Années publiées : un jeu `balances-comptables-des-communes-en-AAAA` par année."""
    url = CATALOG + "?" + urlencode({"where": 'search("balances-comptables-des-communes-en")', "limit": 100, "select": "dataset_id"})
    r = requests.get(url, timeout=60)
    r.raise_for_status()
    return sorted({int(m.group(1)) for x in r.json().get("results", []) if (m := DATASET_RE.fullmatch(x["dataset_id"]))})


def sync_year(year: int, expected: int, force: bool = False) -> None:
    for attempt in range(1, MAX_ATTEMPTS + 1):
        path, rows = download_year(year)
        if rows == expected:
            break
        print(f"  [{year}] tentative {attempt} : {rows:,} lignes pour {expected:,} annoncées — export tronqué, on recommence")
    else:
        raise NR.GuardError(f"✗ [{year}] export toujours incomplet après {MAX_ATTEMPTS} tentatives — table inchangée")
    NR.replace_year(TABLE, YEAR_COL, year, path, BQ_SCHEMA, expected_rows=expected, load_args=LOAD_ARGS, force=force)


def main() -> int:
    ap = argparse.ArgumentParser(description="DGFiP balances → raw_national, année par année")
    ap.add_argument("--years", type=int, nargs="+", help="recharger ces années (sinon : années manquantes ou changées)")
    ap.add_argument("--dry-run", action="store_true", help="dire ce qui serait chargé, sans télécharger ni écrire")
    ap.add_argument("--force", action="store_true", help="accepter une baisse de volume sur une année")
    args = ap.parse_args()

    have = NR.rows_by_year(TABLE, YEAR_COL)
    published = available_years()
    floor = min(have) if have else FIRST_YEAR
    years = args.years or [y for y in published if y >= floor]
    print(f"→ DGFiP balances → {NR.DATASET_ID}.{TABLE} — publiées {published[0] if published else '?'}–{published[-1] if published else '?'}, en table {sorted(have)}")

    todo = []
    for year in years:
        exp = expected_count(year)
        cur = have.get(year, 0)
        state = "à jour" if cur == exp else ("absente" if not cur else f"différente ({cur:,} en table)")
        print(f"  [{year}] serveur {exp:,} lignes — {state}")
        if args.years or cur != exp:
            todo.append((year, exp))
    if not todo:
        print("  = toutes les années publiées sont à jour — rien à faire")
        return 0
    if args.dry_run or NR.CHECK_ONLY:
        for y, exp in todo:
            if NR.CHECK_ONLY:
                NR.would_change(TABLE, f"{y} : {have.get(y, 0):,} → {exp:,} lignes")
        print(f"  (dry-run) à charger : {[y for y, _ in todo]}")
        return 0
    for year, exp in todo:
        sync_year(year, exp, force=args.force)
    print(f"✓ {NR.DATASET_ID}.{TABLE} : {len(todo)} année(s) rechargée(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
