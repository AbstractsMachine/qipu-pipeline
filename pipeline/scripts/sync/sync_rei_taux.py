#!/usr/bin/env python3
"""
National ingest — REI (recensement des éléments d'imposition à la fiscalité
directe locale, DGFiP) → raw_national.rei_taux (BigQuery).

Une archive zip par année sur data.economie.gouv.fr (pièces jointes du jeu
« Impôts locaux : fichier REI »), contenant REI_{année}.csv (1 043 colonnes,
latin-1, « ; »). On ne garde que les taux qui parlent à un habitant :

  E12      taxe foncière sur le bâti, taux appliqué par la commune (%)
  E12VOTE  idem, taux voté (différent en cas de convergence après fusion)
  E32      taxe foncière sur le bâti, taux de l'intercommunalité (%)
  B12      taxe foncière sur le non-bâti, taux de la commune (%)

Mise à jour automatique (2026-09-14) : par défaut, le script lit les années
publiées (pièces jointes du jeu), charge celles qui manquent à la table, une
par une, par _national_raw.replace_year. Avant, il remplaçait la table avec
les seules années de --years : un appel avec une année effaçait les autres.
Seules les archives à partir de 2023 contiennent un CSV (avant : un tableur).

Usage :
    python scripts/sync/sync_rei_taux.py                  # années publiées manquantes
    python scripts/sync/sync_rei_taux.py --dry-run        # dit ce qui serait chargé
    python scripts/sync/sync_rei_taux.py --years 2025     # recharge ces années
"""
from __future__ import annotations

import argparse
import csv
import io
import re
import json
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _national_raw as NR  # noqa: E402

PROJECT_ID = "open-data-france-484717"
DATASET_ID = "raw_national"
TABLE = "rei_taux"
URL = "https://data.economie.gouv.fr/api/v2/catalog/datasets/impots-locaux-fichier-de-recensement-des-elements-dimposition-a-la-fiscalite-dir/attachments/rei_{year}_fichier_notice_trace{suffix}"
SUFFIXES = ["zip", "_zip"]
KEEP = ["DEP", "COM", "LIBCOM", "SIREPCI", "Q03", "E12", "E12VOTE", "E32", "B12"]
BQ_SCHEMA = "annee:INTEGER,dep:STRING,com:STRING,libcom:STRING,siren_epci:STRING,nom_epci:STRING,tfb_commune:FLOAT,tfb_commune_vote:FLOAT,tfb_epci:FLOAT,tfnb_commune:FLOAT"
ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = ROOT / "cache" / "wip" / "national" / "rei"


def num(x: str) -> str:
    x = (x or "").strip().replace(",", ".")
    try:
        return str(float(x))
    except ValueError:
        return ""


def fetch_zip(year: int) -> Path:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    out = CACHE_DIR / f"rei_{year}.zip"
    if out.exists() and out.stat().st_size > 1e6:
        return out
    for suf in SUFFIXES:
        try:
            urllib.request.urlretrieve(URL.format(year=year, suffix=suf), out)
            if out.stat().st_size > 1e6:
                return out
        except Exception as e:  # noqa: BLE001
            print(f"  [{year}] {suf}: {e}")
    raise SystemExit(f"[{year}] archive REI introuvable")


ATTACHMENTS = "https://data.economie.gouv.fr/api/explore/v2.1/catalog/datasets/impots-locaux-fichier-de-recensement-des-elements-dimposition-a-la-fiscalite-dir/attachments"
FIRST_YEAR = 2023  # première archive au format CSV
YEAR_COL = "annee"


def available_years() -> list[int]:
    with urllib.request.urlopen(ATTACHMENTS, timeout=60) as r:
        d = json.load(r)
    return sorted({int(m.group(1)) for a in d.get("attachments", [])
                   if (m := re.search(r"rei_(\d{4})_fichier_notice_trace", a.get("href", "")))})


def build_year_csv(year: int) -> tuple[Path, int] | None:
    z = fetch_zip(year)
    with zipfile.ZipFile(z) as zf:
        name = next((m for m in zf.namelist() if m.lower().endswith(".csv")), None)
        if not name:
            print(f"  [{year}] pas de CSV dans l'archive ({zf.namelist()}) — année sautée")
            return None
        raw = zf.read(name).decode("latin-1")
    reader = csv.DictReader(io.StringIO(raw), delimiter=";")
    missing = [k for k in KEEP if k not in (reader.fieldnames or [])]
    if missing:
        print(f"  [{year}] colonnes absentes : {missing} — année sautée")
        return None
    out = CACHE_DIR / f"rei_taux_{year}.csv"
    k = 0
    with open(out, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["annee", "dep", "com", "libcom", "siren_epci", "nom_epci", "tfb_commune", "tfb_commune_vote", "tfb_epci", "tfnb_commune"])
        for row in reader:
            w.writerow([year, row["DEP"].strip(), row["COM"].strip(), row["LIBCOM"].strip(), row["SIREPCI"].strip(), row["Q03"].strip(),
                        num(row["E12"]), num(row["E12VOTE"]), num(row["E32"]), num(row["B12"])])
            k += 1
    print(f"  [{year}] {k:,} communes → {out.name}")
    return out, k


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--years", type=int, nargs="+", help="recharger ces années (sinon : années publiées manquantes)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    have = NR.rows_by_year(TABLE, YEAR_COL)
    published = [y for y in available_years() if y >= FIRST_YEAR]
    todo = args.years or [y for y in published if y not in have]
    print(f"→ REI → {NR.DATASET_ID}.{TABLE} — publiées {published}, en table {sorted(have)}, à charger {todo}")
    if not todo:
        print("  = rien à faire")
        return 0
    if args.dry_run or NR.CHECK_ONLY:
        for y in todo if NR.CHECK_ONLY else []:
            NR.would_change(TABLE, f"{y} : absente")
        return 0
    for year in todo:
        built = build_year_csv(year)
        if built:
            path, rows = built
            NR.replace_year(TABLE, YEAR_COL, year, path, BQ_SCHEMA, expected_rows=rows,
                            load_args=("--source_format=CSV", "--skip_leading_rows=1"), force=args.force)
    return 0


if __name__ == "__main__":
    sys.exit(main())
