#!/usr/bin/env python3
"""
DRIHL, demandes et attributions de logements sociaux → raw_national.drihl_paris
(2026-09-23).

La file d'attente du logement social à Paris (page Logement) venait d'un seed,
seed_drihl_paris_2024.csv, fabriqué à la main avec
pipeline/scripts/tools/extract_drihl_xlsx.py. La DRIHL a publié 2025 depuis
(205 216 demandes, délai médian 34,2 mois) sans que rien ne le charge.

La DRIHL publie un classeur par année à une adresse fixe
(…/IMG/xlsx/socle_demandes_attributions_<année>.xlsx). La veille demande
l'en-tête de chaque année depuis 2022 : une année nouvelle, ou un classeur dont
la date ou la taille a changé, et la table est rechargée — toutes les années,
lues par l'extracteur existant (même lecture que le seed : 2024 identique,
vérifié le 23/09). stg_drihl_paris ne garde que la dernière année ; les autres
restent ici pour l'historique.
"""
from __future__ import annotations

import argparse
import csv
import sys
from datetime import date
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "tools"))
import _national_raw as NR  # noqa: E402
from extract_drihl_xlsx import DEFAULT_URL_TPL, extract  # noqa: E402

TABLE = "drihl_paris"
FIRST_YEAR = 2022
COLUMNS = ["code_insee", "nom", "niveau_geo", "annee", "demandes_choix1", "attributions", "ratio_dem_attrib",
           "delai_median_attribution_mois", "part_anciennete_5ans_plus", "source", "source_url"]
BQ_SCHEMA = ("code_insee:STRING,nom:STRING,niveau_geo:STRING,annee:INTEGER,demandes_choix1:INTEGER,attributions:INTEGER,"
             "ratio_dem_attrib:FLOAT,delai_median_attribution_mois:FLOAT,part_anciennete_5ans_plus:FLOAT,source:STRING,source_url:STRING")
UA = {"User-Agent": "Mozilla/5.0 (qipu-pipeline)"}
CACHE_DIR = HERE.parents[1] / "cache" / "wip" / "national" / "drihl"


def published() -> dict[str, dict]:
    """{year: {last_modified, length}} for every workbook the DRIHL serves."""
    out: dict[str, dict] = {}
    for y in range(FIRST_YEAR, date.today().year + 1):
        try:
            with urlopen(Request(DEFAULT_URL_TPL.format(year=y), headers=UA, method="HEAD"), timeout=60) as r:
                out[str(y)] = {"last_modified": r.headers.get("Last-Modified", ""), "length": r.headers.get("Content-Length", "")}
        except HTTPError as e:
            if e.code != 404:
                raise
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    version = published()
    if not version:
        raise SystemExit("✗ aucun classeur DRIHL trouvé — l'adresse a-t-elle changé ?")
    if NR.is_version_current(TABLE, version) and not args.force:
        print(f"  = {TABLE} : {', '.join(version)} déjà chargés — rien à faire")
        return 0
    old = NR.meta(TABLE).get("version") or {}
    changed = [y for y in version if old.get(y) != version[y]]
    print(f"→ DRIHL → {NR.DATASET_ID}.{TABLE} — nouveau ou modifié : {', '.join(changed)}")
    if args.dry_run or NR.CHECK_ONLY:
        if NR.CHECK_ONLY:
            NR.would_change(TABLE, ", ".join(changed))
        return 0

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    out = CACHE_DIR / "drihl_paris.csv"
    n = 0
    with open(out, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        w.writeheader()
        for y in sorted(version):
            xlsx = CACHE_DIR / f"socle_{y}.xlsx"
            with urlopen(Request(DEFAULT_URL_TPL.format(year=y), headers=UA), timeout=300) as r:
                xlsx.write_bytes(r.read())
            rows = extract(xlsx, int(y))
            if not any(r["code_insee"] == "75" for r in rows):
                raise SystemExit(f"✗ {y} : pas de ligne Paris dans le classeur — table inchangée")
            for r in rows:
                w.writerow({c: ("" if r.get(c) is None else r.get(c)) for c in COLUMNS})
            n += len(rows)
            print(f"  {y} : {len(rows)} lignes")
    NR.replace_snapshot(TABLE, out, BQ_SCHEMA, version=version,
                        load_args=("--source_format=CSV", "--skip_leading_rows=1"), force=args.force)
    print(f"✓ {n} lignes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
