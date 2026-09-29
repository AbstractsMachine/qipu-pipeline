#!/usr/bin/env python3
"""
National ingest — OFGL consolidated aggregates → raw_national.ofgl_communes (BigQuery).
Source: data.ofgl.fr, ODS Explore v2.1, `ofgl-base-communes-consolidee` (LONG:
        one row per commune × year × agregat).

Serves TWO jobs at once (national-first, ungated, ALL ~35k communes):
  1. Commune dimension — siren, insee (com_code), name, dep/reg, population (ptot).
     This is the universe the budget models join against (NOT seed_communes_cibles).
  2. Reconciliation top-lines — `montant_bp` is the *budget principal* figure, which
     reconciles directly against the DGFiP balances filtered to cbudg="1".

Mise à jour automatique (2026-09-14) :
    Tous les agrégats sont chargés par défaut : c'est ce que contient la table
    depuis le 2026-09-09 (sync --all-agregats), et une année chargée avec la
    liste courte y aurait côtoyé des années complètes. Par défaut, le script
    compare année par année le nombre de lignes publié à celui de la table et
    ne recharge que les années absentes ou différentes, par
    _national_raw.replace_year. Constat du jour : 2024 était tronqué en table
    (1 123 501 lignes pour 1 698 387 publiées) et 2025 absent.

Usage:
    python scripts/sync/sync_ofgl_national.py                 # années manquantes ou changées
    python scripts/sync/sync_ofgl_national.py --dry-run       # dit ce qui serait chargé
    python scripts/sync/sync_ofgl_national.py --years 2024    # recharge ces années
    python scripts/sync/sync_ofgl_national.py --liste-agregats --years 2024   # liste courte (diagnostic)

Output:
    BigQuery table open-data-france-484717.raw_national.ofgl_communes
"""

import argparse
import sys
from pathlib import Path
from urllib.parse import urlencode

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _national_raw as NR  # noqa: E402

TABLE = "ofgl_communes"
YEAR_COL = "exer"

OFGL_EXPORT = (
    "https://data.ofgl.fr/api/explore/v2.1/catalog/datasets/"
    "ofgl-base-communes-consolidee/exports/csv"
)
OFGL_RECORDS = (
    "https://data.ofgl.fr/api/explore/v2.1/catalog/datasets/"
    "ofgl-base-communes-consolidee/records"
)

# Aggregates we ingest: dimension carrier + reconciliation top-lines + context KPIs.
AGREGATS = [
    "Dépenses de fonctionnement",
    "Recettes de fonctionnement",
    "Dépenses d'investissement hors remb",
    "Recettes d'investissement hors emprunts",
    "Dépenses d'équipement",
    "Dépenses totales",
    "Recettes totales",
    "Encours de dette",
    "Annuité de la dette",
    "Epargne brute",
    "Epargne nette",
]

SELECT = (
    "exer,siren,com_code,com_name,dep_code,dep_name,reg_code,reg_name,"
    "categ,ptot,tranche_population,agregat,montant,montant_bp,montant_ba,"
    "euros_par_habitant"
)

BQ_SCHEMA = (
    "exer:INTEGER,siren:STRING,com_code:STRING,com_name:STRING,"
    "dep_code:STRING,dep_name:STRING,reg_code:STRING,reg_name:STRING,"
    "categ:STRING,ptot:FLOAT,tranche_population:STRING,agregat:STRING,"
    "montant:FLOAT,montant_bp:FLOAT,montant_ba:FLOAT,euros_par_habitant:FLOAT"
)

ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = ROOT / "cache" / "wip" / "national" / "ofgl"

FIRST_YEAR = 2018
MAX_ATTEMPTS = 5
LOAD_ARGS = ("--source_format=CSV", "--skip_leading_rows=1", "--field_delimiter=;")


ALL_AGREGATS = True  # --liste-agregats pour la liste courte AGREGATS ; défaut = tout, comme la table : les 53 agrégats OFGL (DGF, subventions versées, fiscalité reversée…)


def _agregat_filter() -> str:
    if ALL_AGREGATS:
        return "agregat IS NOT NULL"
    quoted = ", ".join(f'"{a}"' for a in AGREGATS)
    return f"agregat IN ({quoted})"


def expected_count(year: int) -> int:
    where = f'year(exer)={year} AND categ="Commune" AND {_agregat_filter()}'
    url = OFGL_RECORDS + "?" + urlencode({"where": where, "limit": 0})
    r = requests.get(url, timeout=60)
    r.raise_for_status()
    return int(r.json().get("total_count", 0))


def download_year(year: int) -> tuple[Path, int]:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    out = CACHE_DIR / f"ofgl_{year}.csv"
    where = f'year(exer)={year} AND categ="Commune" AND {_agregat_filter()}'
    url = OFGL_EXPORT + "?" + urlencode(
        {"where": where, "select": SELECT, "delimiter": ";", "use_labels": "false"}
    )
    print(f"  [{year}] streaming OFGL export → {out.name}")
    n_lines = 0
    with requests.get(url, stream=True, timeout=900) as resp:
        resp.raise_for_status()
        with open(out, "wb") as f:
            for chunk in resp.iter_content(chunk_size=1 << 20):
                if chunk:
                    f.write(chunk)
                    n_lines += chunk.count(b"\n")
    data_rows = max(n_lines - 1, 0)
    print(f"  [{year}] ~{data_rows:,} rows ({out.stat().st_size / 1024:.0f} KB)")
    return out, data_rows


def published_counts() -> dict[int, int]:
    """Lignes publiées par année, avec le filtre même du chargement."""
    where = f'categ="Commune" AND {_agregat_filter()}'
    # L'API ignore l'alias d'un group_by sur une expression (« year(exer) as y »
    # rend y = None) : on regroupe sur la date d'exercice elle-même.
    url = OFGL_RECORDS + "?" + urlencode({"select": "exer, count(*) as n", "where": where, "group_by": "exer", "limit": 100})
    r = requests.get(url, timeout=120)
    r.raise_for_status()
    return {int(str(x["exer"])[:4]): int(x["n"]) for x in r.json().get("results", []) if x.get("exer")}


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
    ap = argparse.ArgumentParser(description="OFGL consolidée → raw_national, année par année")
    ap.add_argument("--years", type=int, nargs="+", help="recharger ces années (sinon : années manquantes ou changées)")
    ap.add_argument("--dry-run", action="store_true", help="dire ce qui serait chargé, sans télécharger ni écrire")
    ap.add_argument("--force", action="store_true", help="accepter une baisse de volume sur une année")
    ap.add_argument("--liste-agregats", action="store_true", help="seulement la liste courte AGREGATS (diagnostic, pas pour la table de prod)")
    ap.add_argument("--all-agregats", action="store_true", help=argparse.SUPPRESS)  # ancien drapeau, désormais le défaut
    args = ap.parse_args()
    global ALL_AGREGATS
    ALL_AGREGATS = not args.liste_agregats

    have = NR.rows_by_year(TABLE, YEAR_COL)
    published = published_counts()
    floor = min(have) if have else FIRST_YEAR
    years = args.years or sorted(y for y in published if y >= floor)
    print(f"→ OFGL consolidée → {NR.DATASET_ID}.{TABLE} — {'tous agrégats' if ALL_AGREGATS else 'liste courte'}, publiées {sorted(published)}, en table {sorted(have)}")

    todo = []
    for year in years:
        exp = published.get(year, 0)
        cur = have.get(year, 0)
        state = "à jour" if cur == exp else ("absente" if not cur else f"différente ({cur:,} en table)")
        print(f"  [{year}] publié {exp:,} lignes — {state}")
        if exp and (args.years or cur != exp):
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
