#!/usr/bin/env python3
"""
Synchronisation des données nationales (DGFiP, OFGL, DECP, Subventions) vers BigQuery.

Ce script télécharge les données financières des 5 plus grandes villes de France
depuis des sources nationales centralisées et les charge dans BigQuery.

Sources:
    - DGFiP Balances Comptables (data.economie.gouv.fr) — comptes M57 par commune
    - OFGL Agrégats (data.ofgl.fr) — KPIs pré-calculés par commune
    - DECP Consolidés (data.gouv.fr) — marchés publics nationaux
    - Subventions SCDL (data.gouv.fr) — subventions > 23k€

Usage:
    # Synchroniser toutes les sources
    python scripts/sync/sync_national.py

    # Synchroniser une source spécifique
    python scripts/sync/sync_national.py --source dgfip_balances

    # Mode dry run
    python scripts/sync/sync_national.py --dry-run

    # Lister les sources
    python scripts/sync/sync_national.py --list

Output:
    - Tables BigQuery dans le dataset 'raw_national'
"""

import argparse
import csv
import io
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

import pandas as pd
import requests

# Add parent to path for shared imports
sys.path.insert(0, str(Path(__file__).parent))
from sync_opendata import clean_column_name, upload_to_bigquery

# =============================================================================
# Configuration
# =============================================================================

PROJECT_ID = "open-data-france-484717"
DATASET_ID = "raw_national"

# API endpoints
DGFIP_API = "https://data.economie.gouv.fr/api/explore/v2.1"
OFGL_API = "https://data.ofgl.fr/api/explore/v2.1"
DATAGOUV_API = "https://www.data.gouv.fr/api/1"

# Years to sync for DGFiP balances
DGFIP_YEARS = list(range(2024, 2016, -1))  # 2024 down to 2017

# Seed file for commune list
SEEDS_DIR = Path(__file__).parent.parent.parent / "seeds"


# =============================================================================
# Load communes cibles from seed
# =============================================================================

def load_communes_cibles() -> list[dict]:
    """Load target communes from seed CSV."""
    csv_path = SEEDS_DIR / "seed_communes_cibles.csv"
    if not csv_path.exists():
        raise FileNotFoundError(f"Seed file not found: {csv_path}")

    communes = []
    with open(csv_path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            communes.append(row)

    print(f"  Loaded {len(communes)} target communes: {', '.join(c['nom'] for c in communes)}")
    return communes


def get_sirens(communes: list[dict]) -> list[str]:
    """Extract SIREN codes from communes list."""
    return [c["siren"] for c in communes]


def get_codes_insee(communes: list[dict]) -> list[str]:
    """Extract INSEE codes from communes list."""
    return [c["code_insee"] for c in communes]


# =============================================================================
# ODS (OpenDataSoft) API helper
# =============================================================================

def download_ods_dataset(
    api_base: str,
    dataset_id: str,
    where_clause: str = "",
    select_clause: str = "",
    limit: int = 100,
    max_records: int = 100_000,
) -> pd.DataFrame:
    """
    Download data from an OpenDataSoft Explore v2.1 API with pagination.

    Args:
        api_base: Base API URL (e.g. https://data.economie.gouv.fr/api/explore/v2.1)
        dataset_id: Dataset identifier
        where_clause: ODSQL WHERE filter
        select_clause: ODSQL SELECT fields
        limit: Records per page (max 100)
        max_records: Safety limit to prevent runaway downloads
    """
    url = f"{api_base}/catalog/datasets/{dataset_id}/records"
    all_records = []
    offset = 0

    while offset < max_records:
        params = {"limit": limit, "offset": offset}
        if where_clause:
            params["where"] = where_clause
        if select_clause:
            params["select"] = select_clause

        response = requests.get(url, params=params, timeout=60)
        response.raise_for_status()
        data = response.json()

        results = data.get("results", [])
        if not results:
            break

        all_records.extend(results)
        total_count = data.get("total_count", 0)

        if offset + limit >= total_count:
            break

        offset += limit
        # Polite delay to avoid rate limiting
        time.sleep(0.3)

    if not all_records:
        return pd.DataFrame()

    df = pd.DataFrame(all_records)
    return df


# =============================================================================
# Source: DGFiP Balances Comptables
# =============================================================================

def sync_dgfip_balances(communes: list[dict], dry_run: bool = False) -> dict:
    """
    Sync DGFiP balance comptable data for target communes.

    One dataset per year on data.economie.gouv.fr.
    Contains all account lines (M57 nature codes) for all communes.
    """
    print(f"\n{'='*60}")
    print(f"  DGFiP BALANCES COMPTABLES")
    print(f"{'='*60}")

    sirens = get_sirens(communes)
    siren_filter = " OR ".join(f"siren='{s}'" for s in sirens)

    all_dfs = []
    for year in DGFIP_YEARS:
        dataset_id = f"balances-comptables-des-communes-en-{year}"
        print(f"\n  [{year}] Dataset: {dataset_id}")

        try:
            df = download_ods_dataset(
                api_base=DGFIP_API,
                dataset_id=dataset_id,
                where_clause=siren_filter,
                max_records=200_000,
            )
            if df.empty:
                print(f"    No data found for {year}")
                continue

            df["annee_balance"] = year
            print(f"    {len(df):,} rows downloaded")
            all_dfs.append(df)

        except requests.exceptions.HTTPError as e:
            if e.response.status_code == 404:
                print(f"    Dataset not found for {year}, skipping")
            else:
                print(f"    HTTP error for {year}: {e}")
        except Exception as e:
            print(f"    Error for {year}: {e}")

    if not all_dfs:
        return {"source": "dgfip_balances", "rows": 0, "status": "empty"}

    df_all = pd.concat(all_dfs, ignore_index=True)
    print(f"\n  Total: {len(df_all):,} rows across {len(all_dfs)} years")

    if dry_run:
        print("  DRY RUN - skipping upload")
        return {"source": "dgfip_balances", "rows": len(df_all), "status": "dry_run"}

    rows = upload_to_bigquery(
        df_all, "dgfip_balances",
        project_id=PROJECT_ID, dataset_id=DATASET_ID,
    )
    return {"source": "dgfip_balances", "rows": rows, "status": "success"}


# =============================================================================
# Source: OFGL Agrégats Communes
# =============================================================================

def sync_ofgl_communes(communes: list[dict], dry_run: bool = False) -> dict:
    """
    Sync OFGL pre-computed aggregate data for target communes.

    Single dataset with KPIs (revenue, expenses, debt, savings rate, etc.)
    for all communes, 2017-2024.
    """
    print(f"\n{'='*60}")
    print(f"  OFGL AGRÉGATS COMMUNES")
    print(f"{'='*60}")

    codes = get_codes_insee(communes)
    code_filter = " OR ".join(f"code_commune='{c}'" for c in codes)

    try:
        df = download_ods_dataset(
            api_base=OFGL_API,
            dataset_id="ofgl-base-communes-v2",
            where_clause=code_filter,
            max_records=50_000,
        )
    except requests.exceptions.HTTPError:
        # Try alternative dataset name
        print("  Trying alternative dataset name...")
        try:
            df = download_ods_dataset(
                api_base=OFGL_API,
                dataset_id="ofgl-base-communes",
                where_clause=code_filter,
                max_records=50_000,
            )
        except Exception as e:
            print(f"  Error: {e}")
            # Try with code_insee instead of code_commune
            code_filter_alt = " OR ".join(f"code_insee='{c}'" for c in codes)
            df = download_ods_dataset(
                api_base=OFGL_API,
                dataset_id="ofgl-base-communes",
                where_clause=code_filter_alt,
                max_records=50_000,
            )

    if df.empty:
        return {"source": "ofgl_communes", "rows": 0, "status": "empty"}

    print(f"  {len(df):,} rows downloaded")

    if dry_run:
        print("  DRY RUN - skipping upload")
        return {"source": "ofgl_communes", "rows": len(df), "status": "dry_run"}

    rows = upload_to_bigquery(
        df, "ofgl_communes",
        project_id=PROJECT_ID, dataset_id=DATASET_ID,
    )
    return {"source": "ofgl_communes", "rows": rows, "status": "success"}


# =============================================================================
# Source: DECP (Marchés Publics) — RETIRÉE (2026-09-13)
# =============================================================================
# L'ancien chargeur filtrait la DECP par les SIREN de seed_communes_cibles.csv
# puis écrasait raw_national.decp_marches (WRITE_TRUNCATE, schéma de l'API
# tabulaire). Ce seed n'a plus de colonne siren : il plantait en silence. S'il
# en avait retrouvé une, il aurait remplacé les 3,1 millions de lignes de la
# table nationale par un sous-ensemble au mauvais schéma. La DECP des communes
# se charge par scripts/sync/sync_decp_national.py.

# =============================================================================
# Source: Subventions Nationales (SCDL)
# =============================================================================

def sync_subventions_nationales(communes: list[dict], dry_run: bool = False) -> dict:
    """
    Sync national subsidies (> 23k€) data from data.gouv.fr.

    Uses the SCDL schema: idAttribuant = SIRET of granting entity.
    """
    print(f"\n{'='*60}")
    print(f"  SUBVENTIONS NATIONALES (SCDL)")
    print(f"{'='*60}")

    sirens = get_sirens(communes)

    # The consolidated subventions dataset on data.gouv.fr
    # Try the tabular API approach
    # Dataset: donnees-essentielles-des-conventions-de-subventions
    resource_id = "6b5b8c23-91ca-4c2b-99b0-c9a0ebf9f6e6"
    api_url = f"https://tabular-api.data.gouv.fr/api/resources/{resource_id}/data/"

    all_records = []
    for siren in sirens:
        commune = next(c for c in communes if c["siren"] == siren)
        siren_9 = siren[:9] if len(siren) > 9 else siren
        print(f"\n  Fetching subventions for {commune['nom']} (SIREN: {siren_9})...")

        page = 1
        page_size = 500
        city_count = 0

        while True:
            try:
                params = {
                    "page": page,
                    "page_size": page_size,
                    "idAttribuant__contains": siren_9,
                }
                response = requests.get(api_url, params=params, timeout=120)
                response.raise_for_status()
                data = response.json()

                records = data.get("data", [])
                if not records:
                    break

                for r in records:
                    r["_commune_slug"] = commune["slug"]
                    r["_commune_nom"] = commune["nom"]
                all_records.extend(records)
                city_count += len(records)

                total = data.get("meta", {}).get("total", 0)
                if page * page_size >= total:
                    break

                page += 1
                time.sleep(0.2)

            except requests.exceptions.HTTPError as e:
                if e.response.status_code == 404:
                    print(f"    Resource not found, trying alternative...")
                    break
                print(f"    HTTP error on page {page}: {e}")
                break
            except Exception as e:
                print(f"    Error on page {page}: {e}")
                break

        print(f"    {city_count:,} subventions found")

    if not all_records:
        print("  No subventions found via tabular API")
        return {"source": "subventions_nationales", "rows": 0, "status": "empty"}

    df = pd.DataFrame(all_records)
    print(f"\n  Total: {len(df):,} subventions across {len(sirens)} cities")

    if dry_run:
        print("  DRY RUN - skipping upload")
        return {"source": "subventions_nationales", "rows": len(df), "status": "dry_run"}

    rows = upload_to_bigquery(
        df, "subventions_nationales",
        project_id=PROJECT_ID, dataset_id=DATASET_ID,
    )
    return {"source": "subventions_nationales", "rows": rows, "status": "success"}


# =============================================================================
# Orchestration
# =============================================================================

SOURCES = {
    "dgfip_balances": sync_dgfip_balances,
    "ofgl_communes": sync_ofgl_communes,
    "subventions_nationales": sync_subventions_nationales,
}


def sync_all(dry_run: bool = False) -> list[dict]:
    """Sync all national data sources."""
    print("\n" + "=" * 60)
    print("  SYNCHRONISATION DONNÉES NATIONALES → BIGQUERY")
    print("=" * 60)
    print(f"  Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  Projet: {PROJECT_ID}")
    print(f"  Dataset: {DATASET_ID}")
    if dry_run:
        print("  MODE DRY RUN")

    communes = load_communes_cibles()
    results = []

    for name, sync_fn in SOURCES.items():
        try:
            result = sync_fn(communes, dry_run=dry_run)
            results.append(result)
        except Exception as e:
            print(f"\n  ERROR for {name}: {e}")
            results.append({"source": name, "rows": 0, "status": "error", "error": str(e)})

    # Summary
    print(f"\n{'='*60}")
    print("  RÉSUMÉ SYNCHRONISATION NATIONALE")
    print(f"{'='*60}")
    total = 0
    for r in results:
        icon = "OK" if r["status"] == "success" else "!!" if r["status"] == "error" else "--"
        rows = r.get("rows", 0)
        total += rows
        print(f"  [{icon}] {r['source']}: {rows:,} lignes ({r['status']})")
    print(f"\n  TOTAL: {total:,} lignes")

    return results


def main():
    parser = argparse.ArgumentParser(
        description="Synchronisation données nationales → BigQuery",
    )
    parser.add_argument("--source", choices=list(SOURCES.keys()), help="Source spécifique")
    parser.add_argument("--list", action="store_true", help="Lister les sources")
    parser.add_argument("--dry-run", action="store_true", help="Télécharger sans uploader")

    args = parser.parse_args()

    if args.list:
        print("\nSources disponibles:")
        for name in SOURCES:
            print(f"  - {name}")
        return

    if args.source:
        communes = load_communes_cibles()
        SOURCES[args.source](communes, dry_run=args.dry_run)
    else:
        sync_all(dry_run=args.dry_run)

    print("\nSynchronisation terminée !")
    print("\nProchaines étapes:")
    print("  1. dbt run --select tag:national")
    print("  2. python scripts/export/export_national.py")


if __name__ == "__main__":
    main()
