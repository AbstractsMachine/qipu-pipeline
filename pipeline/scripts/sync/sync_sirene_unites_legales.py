#!/usr/bin/env python3
"""
National ingest — SIRENE unités légales → raw_national.sirene_unites_legales.

Pourquoi : savoir si un titulaire de marché public est une personne physique
(entrepreneur individuel, catégorie juridique 1000) pour ne jamais lui faire
une fiche ni l'afficher nommément (règle vie privée du site, même règle que
pour les bénéficiaires de subventions).

Source : INSEE, base Sirene, fichier StockUniteLegale (parquet, data.gouv.fr),
licence ouverte. ~25 M unités légales. On ne garde que les colonnes utiles au
site ; la table raw reste une copie fidèle de ces colonnes.

Mise à jour automatique (2026-09-14) : table remplacée seulement quand l'INSEE publie un nouveau stock, garde de 90 % (_national_raw).

Usage :
    python scripts/sync/sync_sirene_unites_legales.py            # nouveau stock → télécharge puis charge
    python scripts/sync/sync_sirene_unites_legales.py --dry-run  # dit s'il y a un nouveau stock
    python scripts/sync/sync_sirene_unites_legales.py --file /tmp/stock-stockunitelegale-parquet.parquet
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _national_raw as NR  # noqa: E402

import pyarrow.parquet as pq
import pyarrow.csv as pcsv

PROJECT_ID = "open-data-france-484717"
DATASET_ID = "raw_national"
TABLE = "sirene_unites_legales"
DATASET_API = "https://www.data.gouv.fr/api/1/datasets/base-sirene-des-entreprises-et-de-leurs-etablissements-siren-siret/"

COLUMNS = [
    "siren",
    "categorieJuridiqueUniteLegale",
    "etatAdministratifUniteLegale",
    "denominationUniteLegale",
    "activitePrincipaleUniteLegale",
    "categorieEntreprise",
    # La taille de l'entreprise (2026-09-25) : « 10 000 salariés et plus » sur la fiche fournisseur.
    "trancheEffectifsUniteLegale",
]
BQ_SCHEMA = (
    "siren:STRING,categorie_juridique:STRING,etat_administratif:STRING,"
    "denomination:STRING,activite_principale:STRING,categorie_entreprise:STRING,tranche_effectifs:STRING"
)

ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = ROOT / "cache" / "wip" / "national" / "sirene"


def latest_resource() -> dict:
    with urllib.request.urlopen(DATASET_API, timeout=60) as r:
        d = json.load(r)
    for res in d["resources"]:
        t = res.get("title") or ""
        if "StockUniteLegale" in t and "Historique" not in t and res.get("format") == "parquet":
            return {"url": res["url"], "last_modified": res.get("last_modified")}
    raise SystemExit("StockUniteLegale parquet introuvable sur data.gouv")


def download(url: str) -> Path:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    out = CACHE_DIR / "stock-stockunitelegale.parquet"
    print(f"  téléchargement → {out}")
    urllib.request.urlretrieve(url, out)
    print(f"  {out.stat().st_size / 1e6:.0f} MB")
    return out


def to_csv(parquet: Path) -> Path:
    """Projette les colonnes utiles en CSV (bq load n'accepte pas de projection parquet)."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    out = CACHE_DIR / "sirene_unites_legales.csv"
    table = pq.read_table(parquet, columns=COLUMNS)
    table = table.rename_columns(
        ["siren", "categorie_juridique", "etat_administratif", "denomination",
         "activite_principale", "categorie_entreprise", "tranche_effectifs"]
    )
    pcsv.write_csv(table, out)
    print(f"  {table.num_rows:,} unités légales → {out.name} ({out.stat().st_size / 1e6:.0f} MB)")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", type=Path, help="parquet StockUniteLegale déjà téléchargé")
    ap.add_argument("--dry-run", action="store_true", help="dit s'il y a une nouvelle version, ne télécharge rien")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    res = latest_resource()
    if NR.is_version_current(TABLE, res) and not args.force and not args.file:
        print(f"  = {TABLE} : stock {res['last_modified']} déjà chargé — rien à faire")
        return 0
    print(f"→ SIRENE → {NR.DATASET_ID}.{TABLE} — nouveau stock {res['last_modified']}")
    if args.dry_run or NR.CHECK_ONLY:
        if NR.CHECK_ONLY:
            NR.would_change(TABLE, f"stock {res['last_modified']}")
        return 0
    parquet = args.file or download(res["url"])
    csv_path = to_csv(parquet)
    NR.replace_snapshot(TABLE, csv_path, BQ_SCHEMA, version=res,
                        load_args=("--source_format=CSV", "--skip_leading_rows=1", "--allow_quoted_newlines"), force=args.force)
    return 0


if __name__ == "__main__":
    sys.exit(main())
