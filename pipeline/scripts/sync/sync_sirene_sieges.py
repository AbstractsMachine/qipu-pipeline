#!/usr/bin/env python3
"""
National ingest — SIRENE, sièges des unités légales → raw_national.sirene_sieges.

Pourquoi (2026-09-25) : la fiche d'un fournisseur de commune dit où est son
siège (« siège à Paris (75) ») — ce qui distingue l'entreprise du coin de la
filiale d'un groupe national. L'unité légale ne porte pas d'adresse : elle est
sur l'établissement siège.

Source : INSEE, base Sirene, fichier StockEtablissement (parquet, data.gouv.fr,
~2,2 Go, ~40 M établissements), licence ouverte. On ne garde que les sièges
(etablissementSiege = vrai) et leur commune ; jamais d'adresse de rue — une
personne physique peut avoir son siège chez elle, et la page ne l'affiche de
toute façon jamais (règle vie privée, stg_sirene_unites_legales).

Mise à jour : comme sync_sirene_unites_legales.py, la table n'est remplacée que
quand l'INSEE publie un nouveau stock (garde de 90 %, _national_raw).

Usage :
    python scripts/sync/sync_sirene_sieges.py            # nouveau stock → télécharge puis charge
    python scripts/sync/sync_sirene_sieges.py --dry-run
    python scripts/sync/sync_sirene_sieges.py --file /tmp/stock-etablissement.parquet
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _national_raw as NR  # noqa: E402

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.csv as pcsv
import pyarrow.parquet as pq

TABLE = "sirene_sieges"
DATASET_API = "https://www.data.gouv.fr/api/1/datasets/base-sirene-des-entreprises-et-de-leurs-etablissements-siren-siret/"
COLUMNS = ["siren", "etablissementSiege", "codeCommuneEtablissement", "libelleCommuneEtablissement",
           "codePostalEtablissement", "etatAdministratifEtablissement"]
OUT_NAMES = ["siren", "code_commune", "libelle_commune", "code_postal", "etat_administratif"]
BQ_SCHEMA = "siren:STRING,code_commune:STRING,libelle_commune:STRING,code_postal:STRING,etat_administratif:STRING"

ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = ROOT / "cache" / "wip" / "national" / "sirene"


def latest_resource() -> dict:
    with urllib.request.urlopen(DATASET_API, timeout=60) as r:
        d = json.load(r)
    for res in d["resources"]:
        t = res.get("title") or ""
        if "StockEtablissement -" in t and "Historique" not in t and "Liens" not in t and res.get("format") == "parquet":
            return {"url": res["url"], "last_modified": res.get("last_modified")}
    raise SystemExit("StockEtablissement parquet introuvable sur data.gouv")


def download(url: str) -> Path:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    out = CACHE_DIR / "stock-etablissement.parquet"
    print(f"  téléchargement → {out}")
    urllib.request.urlretrieve(url, out)
    return out


def to_csv(parquet: Path) -> Path:
    """Les sièges seulement, lot par lot (le fichier entier ne tient pas en mémoire)."""
    out = CACHE_DIR / "sirene_sieges.csv"
    pf = pq.ParquetFile(parquet)
    n = 0
    with pcsv.CSVWriter(out, pa.schema([(c, pa.string()) for c in OUT_NAMES])) as w:
        for batch in pf.iter_batches(batch_size=500_000, columns=COLUMNS):
            t = pa.Table.from_batches([batch])
            siege = t.column("etablissementSiege")
            mask = pc.fill_null(pc.equal(pc.cast(siege, pa.string()), "true"), False)
            t = t.filter(mask).drop(["etablissementSiege"])
            t = pa.table({name: pc.cast(t.column(src), pa.string()) for name, src in zip(OUT_NAMES, [c for c in COLUMNS if c != "etablissementSiege"])})
            w.write_table(t)
            n += t.num_rows
    print(f"  {n:,} sièges → {out.name} ({out.stat().st_size / 1e6:.0f} MB)")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", type=Path, help="parquet StockEtablissement déjà téléchargé")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    res = latest_resource()
    if NR.is_version_current(TABLE, res) and not args.force and not args.file:
        print(f"  = {TABLE} : stock {res['last_modified']} déjà chargé — rien à faire")
        return 0
    print(f"→ SIRENE sièges → {NR.DATASET_ID}.{TABLE} — nouveau stock {res['last_modified']}")
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
