#!/usr/bin/env python3
"""
Sync OpenData Paris `dette-garantie` (annexe IV-B emprunts garantis) → BigQuery.

Source: opendata.paris.fr API (filtré collectivite='Ville de Paris').
Cible: BigQuery `open-data-france-484717.raw.dette_garantie_paris`.

Usage:
    python pipeline/scripts/sync/sync_dette_garantie.py
    python pipeline/scripts/sync/sync_dette_garantie.py --years 2019,2020,2021,2022,2023,2024
"""

from __future__ import annotations

import argparse
import io
import sys
from pathlib import Path

import pandas as pd
import requests
from google.cloud import bigquery

sys.path.insert(0, str(Path(__file__).parent.parent))
from utils.logger import Logger

PROJECT_ID = "open-data-france-484717"
RAW_DATASET = "raw"
RAW_TABLE = "dette_garantie_paris"
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _paris_portal  # noqa: E402
API_BASE = _paris_portal.api("/catalog/datasets/dette-garantie")
# Les exercices ne sont plus écrits à la main. La liste figée s'arrêtait à
# 2019-2024 alors que la source publie de 2007 à 2025 pour la Ville de Paris :
# douze exercices et environ 94 000 lignes n'étaient jamais ingérés, donc
# jamais exportés, sans qu'aucun commentaire ne dise pourquoi (constaté
# 2026-09-10). On demande au portail quels exercices il porte.
FALLBACK_YEARS = [2019, 2020, 2021, 2022, 2023, 2024]


def annees_publiees(logger) -> list[int]:
    """Les exercices que le portail porte pour la Ville de Paris."""
    import json as _json
    import urllib.parse as _up
    import urllib.request as _ur
    url = (f"{API_BASE}/records?" + _up.urlencode({
        "select": "annee_de_publication, count(*) as n",
        "group_by": "annee_de_publication",
        "where": 'collectivite="Ville de Paris"', "limit": "100"}))
    try:
        req = _ur.Request(url, headers={"User-Agent": "qipu/0.1 (qipu.org)"})
        data = _json.loads(_ur.urlopen(req, timeout=60).read())
        annees = sorted({int(str(r["annee_de_publication"])[:4])
                         for r in data.get("results", []) if r.get("annee_de_publication")})
        if annees:
            return annees
    except Exception as exc:  # noqa: BLE001
        logger.info(f"exercices illisibles ({type(exc).__name__}), repli sur la liste figée : {exc}")
    return FALLBACK_YEARS


DEFAULT_YEARS = FALLBACK_YEARS


def fetch_year(year: int, logger: Logger) -> pd.DataFrame:
    params = {
        "refine": [f"annee_de_publication:{year}", "collectivite:Ville de Paris"],
        "delimiter": ";",
    }
    url = f"{API_BASE}/exports/csv"
    logger.info(f"Fetch {year} · GET {url}")
    r = requests.get(url, params=params, timeout=180)
    r.raise_for_status()
    df = pd.read_csv(io.StringIO(r.text), sep=";")
    logger.info(f"  → {len(df):,} emprunts garantis")
    return df


def upload(df: pd.DataFrame, client: bigquery.Client, logger: Logger) -> None:
    table_ref = f"{PROJECT_ID}.{RAW_DATASET}.{RAW_TABLE}"
    job_config = bigquery.LoadJobConfig(
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        autodetect=True,
    )
    logger.info(f"Upload → {table_ref} (truncate + load, {len(df):,} rows)")
    df["loaded_at"] = pd.Timestamp.utcnow()
    job = client.load_table_from_dataframe(df, table_ref, job_config=job_config)
    job.result()
    logger.success("Loaded")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--years", default=None,
                        help="exercices séparés par des virgules ; par défaut, ceux que le portail publie")
    args = parser.parse_args()
    logger = Logger("sync_dette_garantie")
    years = ([int(y) for y in args.years.split(",") if y.strip()]
             if args.years else annees_publiees(logger))
    logger.header(f"Sync dette-garantie · {len(years)} années "
                  f"({years[0]}→{years[-1]})")

    frames = []
    for y in years:
        try:
            frames.append(fetch_year(y, logger))
        except Exception as e:
            logger.error(f"  fetch {y} failed: {e}")
            raise
    df = pd.concat(frames, ignore_index=True)
    logger.info(f"Total: {len(df):,} rows over {len(years)} years")

    client = bigquery.Client(project=PROJECT_ID)
    upload(df, client, logger)
    logger.success("Done")


if __name__ == "__main__":
    main()
