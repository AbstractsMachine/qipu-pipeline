#!/usr/bin/env python3
"""
National ingest — DECP consolidée (data.gouv.fr) → raw_national.decp_marches (BigQuery).

Source : « Données essentielles de la commande publique — consolidées, format
tabulaire », fichier decp.parquet, republié chaque jour par data.gouv.fr (une
ligne par marché × titulaire, ~3 millions de lignes, ~250 Mo). Toute la France,
tous acheteurs : le rattachement aux communes se fait en dbt (stg_decp_marches,
par SIREN de l'acheteur joint à l'univers OFGL).

Pourquoi ce script existe (2026-09-13) : la table avait été chargée une seule
fois à la main, le 22 juillet, et l'étape « DECP hebdomadaire » ajoutée ensuite
appelait un ancien chargeur qui plantait en silence. Rien ne la rafraîchissait.

Garde-fous, dans l'ordre :
  1. inchangé    — l'URL et la date de la ressource sont écrites dans la
                   description de la table ; même version → rien à faire.
  2. fichier     — le parquet est relu : colonnes indispensables présentes,
                   nombre de lignes lisible.
  3. chargement  — dans une table temporaire, dont le nombre de lignes doit
                   égaler celui du fichier.
  4. volume      — la nouvelle version doit compter au moins MIN_KEEP_RATIO des
                   lignes de la table actuelle, sinon on refuse d'écraser (un
                   fichier tronqué ne vide pas le site). --force pour passer.
  Seulement alors, la table temporaire remplace la table (copie WRITE_TRUNCATE).

Usage :
    python scripts/sync/sync_decp_national.py             # charge si nouvelle version
    python scripts/sync/sync_decp_national.py --dry-run   # télécharge et contrôle, ne charge pas
    python scripts/sync/sync_decp_national.py --force     # recharge même inchangé / en baisse
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import requests
from google.api_core.exceptions import NotFound
from google.cloud import bigquery

PROJECT_ID = "open-data-france-484717"
DATASET_ID = "raw_national"
TABLE = "decp_marches"
TEMP_TABLE = f"{TABLE}__nouveau"

DATASET_API = "https://www.data.gouv.fr/api/1/datasets/donnees-essentielles-de-la-commande-publique-consolidees-format-tabulaire/"
RESOURCE_TITLE = "decp.parquet"
CACHE_DIR = Path(__file__).resolve().parents[2] / "cache" / "wip" / "national" / "decp"

MIN_KEEP_RATIO = 0.9
# Ce que stg_decp_marches lit. Une colonne absente = le fichier a changé de forme :
# on s'arrête avant d'écraser quoi que ce soit.
REQUIRED_COLUMNS = {
    "uid", "id", "acheteur_id", "acheteur_nom", "objet", "nature", "procedure", "codeCPV",
    "montant", "formePrix", "dateNotification", "dureeMois", "titulaire_id", "titulaire_nom",
    "titulaire_typeIdentifiant", "donneesActuelles", "modification_id", "offresRecues", "ccag",
    "techniques", "considerationsSociales", "considerationsEnvironnementales",
    "sousTraitanceDeclaree", "lieuExecution_code", "lieuExecution_typeCode", "idAccordCadre",
}


# Client Python plutôt que la CLI bq : en CI (Workload Identity Federation),
# `bq show --format=json` sortait 0 avec une sortie vide (run 34954677121,
# 2026-09-15). Le client lit les mêmes identifiants que dbt et les autres jobs.
_client: bigquery.Client | None = None


def client() -> bigquery.Client:
    global _client
    if _client is None:
        _client = bigquery.Client(project=PROJECT_ID)
    return _client


def table_id(table: str) -> str:
    return f"{PROJECT_ID}.{DATASET_ID}.{table}"


def current_resource() -> dict:
    r = requests.get(DATASET_API, timeout=60)
    r.raise_for_status()
    for res in r.json().get("resources", []):
        if res.get("title") == RESOURCE_TITLE:
            return {"url": res["url"], "last_modified": res.get("last_modified"), "filesize": res.get("filesize")}
    raise SystemExit(f"✗ Ressource « {RESOURCE_TITLE} » introuvable sur data.gouv.fr — l'API a changé ?")


def table_info(table: str) -> dict | None:
    # Seule l'absence de la table vaut None. Toute autre erreur (droits, réseau)
    # remonte : la prendre pour « table absente » sauterait le contrôle de volume.
    try:
        t = client().get_table(table_id(table))
    except NotFound:
        return None
    return {"rows": int(t.num_rows or 0), "description": t.description or ""}


def fingerprint(res: dict) -> str:
    return f"source={res['url']} ; last_modified={res['last_modified']}"


def download(res: dict) -> Path:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    dest = CACHE_DIR / "decp.parquet"
    tmp = dest.with_suffix(".parquet.part")
    print(f"  ↓ {res['url']}")
    with requests.get(res["url"], stream=True, timeout=600) as r:
        r.raise_for_status()
        with open(tmp, "wb") as f:
            for chunk in r.iter_content(chunk_size=8 << 20):
                f.write(chunk)
    size = tmp.stat().st_size
    if res.get("filesize") and abs(size - int(res["filesize"])) > 1024:
        raise SystemExit(f"✗ Téléchargement incomplet : {size} octets pour {res['filesize']} annoncés.")
    tmp.replace(dest)
    print(f"    {size / 1e6:.0f} Mo")
    return dest


def check_file(path: Path) -> int:
    import pyarrow.parquet as pq

    meta = pq.ParquetFile(path)
    cols = set(meta.schema_arrow.names)
    missing = sorted(REQUIRED_COLUMNS - cols)
    if missing:
        raise SystemExit(f"✗ Colonnes absentes du fichier : {', '.join(missing)} — raw inchangé.")
    rows = meta.metadata.num_rows
    if rows <= 0:
        raise SystemExit("✗ Fichier vide — raw inchangé.")
    print(f"  ✓ fichier : {rows:,} lignes, {len(cols)} colonnes".replace(",", " "))
    return rows


def load_parquet(path: Path, table: str) -> None:
    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.PARQUET,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )
    with open(path, "rb") as f:
        client().load_table_from_file(f, table_id(table), job_config=job_config).result()


def promote(src: str, dest: str, description: str) -> None:
    """La table temporaire remplace la table, reçoit l'empreinte, puis disparaît."""
    job_config = bigquery.CopyJobConfig(write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE)
    client().copy_table(table_id(src), table_id(dest), job_config=job_config).result()
    t = client().get_table(table_id(dest))
    t.description = description
    client().update_table(t, ["description"])
    client().delete_table(table_id(src), not_found_ok=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="télécharge et contrôle, ne charge pas")
    ap.add_argument("--force", action="store_true", help="recharge même si inchangé, et accepte une baisse de volume")
    args = ap.parse_args()

    print("DECP consolidée → raw_national.decp_marches")
    res = current_resource()
    print(f"  version data.gouv : {res['last_modified']}")
    before = table_info(TABLE)
    if before and before["description"] == fingerprint(res) and not args.force:
        print(f"  = inchangée depuis le dernier chargement ({before['rows']:,} lignes) — rien à faire".replace(",", " "))
        return 0

    rows = check_file(download(res))
    if args.dry_run:
        print("  (dry-run) rien n'est chargé")
        return 0
    if before and rows < MIN_KEEP_RATIO * before["rows"] and not args.force:
        raise SystemExit(
            f"✗ {rows:,} lignes contre {before['rows']:,} aujourd'hui (< {MIN_KEEP_RATIO:.0%}) : "
            "fichier tronqué ou source en panne, on n'écrase pas. --force pour passer outre.".replace(",", " ")
        )

    path = CACHE_DIR / "decp.parquet"
    print(f"  load → {DATASET_ID}.{TEMP_TABLE}")
    load_parquet(path, TEMP_TABLE)
    loaded = table_info(TEMP_TABLE)
    if not loaded or loaded["rows"] != rows:
        raise SystemExit(f"✗ Chargement incomplet : {loaded['rows'] if loaded else 0} lignes pour {rows} dans le fichier — table temporaire laissée pour examen.")

    promote(TEMP_TABLE, TABLE, fingerprint(res))
    delta = f" ({rows - before['rows']:+,} lignes)".replace(",", " ") if before else ""
    print(f"  ✓ {DATASET_ID}.{TABLE} : {rows:,} lignes{delta}".replace(",", " "))
    return 0


if __name__ == "__main__":
    sys.exit(main())
