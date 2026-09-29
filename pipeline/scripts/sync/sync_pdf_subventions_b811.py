#!/usr/bin/env python3
"""
Sync subventions extraites de l'Annexe B8.1.1 du Compte Administratif (PDF)
→ BigQuery raw.

Pourquoi cette source existe :
    Sur les exercices 2020 et 2021, le dataset OpenData Paris
    `subventions-versees-annexe-compte-administratif-a-partir-de-2018`
    expose les montants mais avec `nom_de_l_organisme_beneficiaire = NULL`
    pour 100 % des lignes. La donnée nommée existe dans l'annexe B8.1.1
    du Compte Administratif (PDF, Tome 3), imposée par la nomenclature
    M57. On la réinjecte via cette source pour combler le trou.

Source = les JSON déjà extraits par
`pipeline/scripts/tools/parse_subv_pdf_text.py` et versionnés sous
`pipeline/raw_extracts/subventions_b811/subv_b811_<year>.json`.

Cette commande joue le rôle d'un sync : prend les JSON, les met à plat,
et les charge dans `raw.pdf_subventions_b811_paris`. La chaîne dbt
(stg_subventions_all → core_subventions → marts) prend ensuite le relais.

2025 (et suivants) : même annexe B8.1.1, publiée en PDF le 1er juillet avant
tout jeu open data, extraite par `parse_subv_pdf_text.py --controle-totaux`
(refus si un sous-total imprimé n'est pas retrouvé au centime).

Usage:
    python pipeline/scripts/sync/sync_pdf_subventions_b811.py
    # Vérifier un nouvel exercice en dev sans toucher `raw` prod :
    python pipeline/scripts/sync/sync_pdf_subventions_b811.py --dataset dbt_paris_dev_<user>_raw
    DBT_PARIS_RAW_PDF_SCHEMA=dbt_paris_dev_<user>_raw dbt run --target dev ...
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import pandas as pd
from google.cloud import bigquery

sys.path.insert(0, str(Path(__file__).parent.parent))
from utils.logger import Logger

PROJECT_ID = "open-data-france-484717"
RAW_DATASET = "raw"
RAW_TABLE = "pdf_subventions_b811_paris"
ROOT = Path(__file__).resolve().parents[3]
JSON_DIR = ROOT / "pipeline" / "raw_extracts" / "subventions_b811"


def load_files(logger: Logger) -> pd.DataFrame:
    """Lit les subv_b811_<year>.json existants et aplatit."""
    rows: list[dict] = []
    # Deux annexes, un seul tableau : la B8.1.1 sous M57 (2020-2021, 2025+) et son
    # ancêtre B1.6/B1.7 sous M14 (2010-2012), retrouvée le 2026-09-11 dans
    # l'archive du mini-site de la Ville. Mêmes colonnes, même gabarit.
    fichiers = sorted(JSON_DIR.glob("subv_b811_*.json")) + \
        sorted((JSON_DIR.parent / "subventions_b16").glob("subv_b16_*.json"))
    for path in fichiers:
        d = json.loads(path.read_text(encoding="utf-8"))
        year = int(d["year"])
        per_year_meta = {
            "annee": year,
            "source_pdf": d.get("source_pdf"),
            "source_section": d.get("source_section"),
            "extraction_date": d.get("extraction_date"),
            "extraction_method": d.get("extraction_method"),
        }
        for r in d.get("data", []) or []:
            rows.append({**per_year_meta, **r})
        logger.info(f"  {path.name}: +{len(d.get('data') or [])} lignes")
    df = pd.DataFrame(rows)
    return df


def upload(df: pd.DataFrame, client: bigquery.Client, logger: Logger,
           dataset: str = RAW_DATASET) -> None:
    table_ref = f"{PROJECT_ID}.{dataset}.{RAW_TABLE}"
    job_config = bigquery.LoadJobConfig(
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        autodetect=True,
    )
    logger.info(f"Upload → {table_ref} (truncate + load, {len(df):,} rows)")
    df["loaded_at"] = pd.Timestamp.utcnow()
    job = client.load_table_from_dataframe(df, table_ref, job_config=job_config)
    job.result()
    logger.success("Loaded")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", default=RAW_DATASET,
                    help="Dataset BigQuery cible (défaut : raw). Un dataset de dev "
                         "permet de vérifier un nouvel exercice sans toucher la prod.")
    args = ap.parse_args()
    logger = Logger("sync_pdf_subventions_b811")
    logger.header("Sync subventions B8.1.1 (Annexe CA PDF) → BigQuery")
    df = load_files(logger)
    if df.empty:
        logger.error(f"Aucun fichier sous {JSON_DIR}")
        sys.exit(1)
    logger.info(f"Total: {len(df):,} lignes · {df['annee'].nunique()} années")
    client = bigquery.Client(project=PROJECT_ID)
    if args.dataset != RAW_DATASET:
        ds = bigquery.Dataset(f"{PROJECT_ID}.{args.dataset}")
        ds.location = "EU"          # même région que raw : sinon dbt ne peut pas joindre
        client.create_dataset(ds, exists_ok=True)
    upload(df, client, logger, args.dataset)
    logger.success("Done")


if __name__ == "__main__":
    main()
