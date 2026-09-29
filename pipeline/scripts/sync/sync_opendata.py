#!/usr/bin/env python3
"""
⚠️ DEPRECATED — remplacé par l'ingester générique ODS.

Utiliser désormais :  python scripts/sync/sync_city.py paris
(config déclarative : configs/cities/paris.yaml ; ingester :
scripts/sync/sync_ods_dataset.py). La parité byte-identique entre ce script et
le nouveau chemin est prouvée par scripts/sync/verify_ods_parity.py (7/7).
Ce fichier est conservé comme fallback un cycle puis sera supprimé.

Synchronisation des données Paris Open Data vers BigQuery.

Ce script télécharge les données fraîches depuis l'API Paris Open Data
et les charge dans BigQuery pour traitement par dbt.

Usage:
    # Synchroniser toutes les sources
    python scripts/sync_opendata.py
    
    # Synchroniser une source spécifique
    python scripts/sync_opendata.py --source budget_execute
    
    # Lister les sources disponibles
    python scripts/sync_opendata.py --list

Datasets synchronisés (7 sources essentielles):
    - budget_principal: Comptes Administratifs - Budget Principal (exécuté, SOURCE DE VÉRITÉ)
    - budget_vote: Budgets Votés - Budget Principal (prévisionnel, 2019-2026)
    - ap_projets: Comptes Administratifs - AP Exécutés (projets nommés)
    - subventions: Annexe CA - Subventions versées (tous bénéficiaires)
    - associations: Subventions associations (avec SIRET pour géoloc)
    - logements_sociaux: Logements sociaux (déjà géolocalisés)
    - marches_publics: Marchés publics (contexte, non sommable)
    
Convention de nommage RAW:
    Table BigQuery = dataset_id OpenData en snake_case

Output:
    - Tables BigQuery dans le dataset 'raw'
"""

import argparse
import io
import json
import os
import re
import sys
import unicodedata
from datetime import datetime
from pathlib import Path
from typing import Optional

import pandas as pd
import requests
from google.cloud import bigquery

# =============================================================================
# Configuration
# =============================================================================

# BigQuery
PROJECT_ID = "open-data-france-484717"
DATASET_ID = "raw"

# API Paris Open Data
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _paris_portal  # noqa: E402
# opendata.paris.fr, or the portal's own address when the name does not resolve (_paris_portal).
OPENDATA_API = _paris_portal.api()

# =============================================================================
# Mapping des sources vers les datasets Paris Open Data
#
# CONVENTION DE NOMMAGE RAW:
#   Table BigQuery = dataset_id OpenData en snake_case (aucune abréviation)
#   Exemple: "comptes-administratifs-budgets-principaux-a-partir-de-2019-m57-ville-departement"
#         → raw.comptes_administratifs_budgets_principaux_a_partir_de_2019_m57_ville_departement
#
# ARCHITECTURE (7 sources essentielles):
# - budget_principal: Budget exécuté (SOURCE DE VÉRITÉ macro, CA)
# - budget_vote: Budget voté (prévisionnel, BP, 2019-2026)
# - ap_projets: AP Exécutés (projets nommés, ~10% du budget I)
# - subventions: Annexe CA subventions (tous bénéficiaires)
# - associations: Subventions associations (avec SIRET pour géoloc)
# - logements_sociaux: Programmes de logements (déjà géolocalisés)
# - marches_publics: Marchés publics (contexte, non sommable)
# =============================================================================
DATASETS = {
    # =========================================================================
    # BUDGET PRINCIPAL - Source de vérité pour les totaux
    # =========================================================================
    "budget_principal": {
        "dataset_id": "comptes-administratifs-budgets-principaux-a-partir-de-2019-m57-ville-departement",
        "description": "Comptes Administratifs - Budget Principal (Exécuté) - M57",
        "year_column": "exercice_comptable",
    },
    
    # =========================================================================
    # INVESTISSEMENTS (AP/CP) - Projets physiques nommés
    # =========================================================================
    "ap_projets": {
        "dataset_id": "comptes-administratifs-autorisations-de-programmes-a-partir-de-2018-m57-ville-de",
        "description": "Comptes Administratifs - AP Exécutés (projets nommés avec mission/direction)",
        "year_column": "exercice_comptable",
    },
    
    # =========================================================================
    # SUBVENTIONS - Détail des bénéficiaires
    # =========================================================================
    "subventions": {
        "dataset_id": "subventions-versees-annexe-compte-administratif-a-partir-de-2018",
        "description": "Annexe CA - Toutes subventions versées",
        "year_column": None,  # Parsé depuis 'publication' ("CA 2023" → 2023)
    },
    "associations": {
        "dataset_id": "subventions-associations-votees-",
        "description": "Subventions aux associations votées (avec SIRET pour géoloc)",
        "year_column": "annee_budgetaire",
    },
    
    # =========================================================================
    # DONNÉES GÉOLOCALISÉES
    # =========================================================================
    "logements_sociaux": {
        "dataset_id": "logements-sociaux-finances-a-paris",
        "description": "Logements sociaux financés à Paris (géolocalisés)",
        "year_column": "annee_du_financement_agrement",
        "drop_columns": ["geo_shape"],  # Colonnes complexes à supprimer
    },
    
    # =========================================================================
    # BUDGET VOTÉ (prévisionnel) - Entité séparée du CA
    # =========================================================================
    "budget_vote": {
        "dataset_id": "budgets-votes-principaux-a-partir-de-2019-m57-ville-departement",
        "description": "Budgets Votés - Budget Principal (Prévisionnel) - M57",
        "year_column": "exercice_comptable",
    },
    
    # =========================================================================
    # CONTEXTE - Ne pas sommer avec le budget
    # =========================================================================
    "marches_publics": {
        "dataset_id": "liste-des-marches-de-la-collectivite-parisienne",
        "description": "Marchés publics (ENVELOPPES PLURIANNUELLES - ne pas sommer)",
        "year_column": "annee_de_notification",
    },
}


def dataset_id_to_table_name(dataset_id: str) -> str:
    """
    Convertit un dataset_id OpenData Paris en nom de table BigQuery valide.
    Remplace les tirets par des underscores (snake_case).
    
    Exemple: "comptes-administratifs-budgets-principaux-a-partir-de-2019-m57-ville-departement"
          -> "comptes_administratifs_budgets_principaux_a_partir_de_2019_m57_ville_departement"
    """
    return dataset_id.replace("-", "_").rstrip("_")


# =============================================================================
# Utilitaires
# =============================================================================

def clean_column_name(name: str) -> str:
    """
    Nettoie un nom de colonne pour BigQuery.
    
    - Supprime les accents
    - Convertit en minuscules
    - Remplace espaces/slashes/parenthèses par underscore
    - Collapse les underscores multiples
    """
    # Supprimer les accents
    name = unicodedata.normalize('NFD', name)
    name = ''.join(c for c in name if unicodedata.category(c) != 'Mn')
    # Minuscules
    name = name.lower()
    # Remplacer caractères spéciaux
    name = re.sub(r'[\s/\(\)\-\.]+', '_', name)
    name = re.sub(r'[^a-z0-9_]', '_', name)
    # Collapse underscores
    name = re.sub(r'_+', '_', name)
    name = name.strip('_')
    return name


def get_dataset_info(dataset_id: str) -> dict:
    """Récupère les métadonnées d'un dataset."""
    url = f"{OPENDATA_API}/catalog/datasets/{dataset_id}"
    response = requests.get(url, timeout=30)
    response.raise_for_status()
    return response.json()


def get_available_years(dataset_id: str, year_column: str) -> list[int]:
    """Récupère les années disponibles pour un dataset."""
    url = f"{OPENDATA_API}/catalog/datasets/{dataset_id}/records"
    params = {
        "group_by": year_column,
        "limit": 50,
    }
    response = requests.get(url, params=params, timeout=30)
    response.raise_for_status()
    data = response.json()
    
    years = []
    for result in data.get("results", []):
        year_value = result.get(year_column)
        if year_value:
            # Gérer les formats date vs integer
            if isinstance(year_value, str) and "T" in year_value:
                year = int(year_value[:4])
            else:
                year = int(year_value)
            years.append(year)
    
    return sorted(years, reverse=True)


def download_dataset(dataset_id: str, limit: int = -1) -> pd.DataFrame:
    """
    Télécharge un dataset complet depuis l'API Paris Open Data.
    
    Utilise l'endpoint export pour éviter les limites de pagination.
    """
    url = f"{OPENDATA_API}/catalog/datasets/{dataset_id}/exports/json"
    params = {"limit": limit}
    
    print(f"  📥 Téléchargement depuis {dataset_id}...")
    response = requests.get(url, params=params, timeout=300, stream=True)
    response.raise_for_status()
    
    # Parser le JSON
    data = response.json()
    
    if not data:
        print(f"  ⚠️ Aucune donnée trouvée")
        return pd.DataFrame()
    
    df = pd.DataFrame(data)
    print(f"  ✓ {len(df):,} lignes téléchargées")
    
    return df


def upload_to_bigquery(
    df: pd.DataFrame,
    table_name: str,
    project_id: str = PROJECT_ID,
    dataset_id: str = DATASET_ID,
    drop_columns: list = None,
) -> int:
    """
    Upload un DataFrame vers BigQuery.
    
    Crée la table si elle n'existe pas, sinon remplace les données.
    
    Args:
        df: DataFrame à uploader
        table_name: Nom de la table destination
        project_id: ID du projet GCP
        dataset_id: ID du dataset BigQuery
        drop_columns: Liste de colonnes à supprimer (pour éviter les types complexes)
    """
    if df.empty:
        print(f"  ⚠️ DataFrame vide, skip upload")
        return 0
    
    # Nettoyer les noms de colonnes
    original_columns = df.columns.tolist()
    new_columns = {col: clean_column_name(col) for col in original_columns}
    df = df.rename(columns=new_columns)
    
    # Supprimer les colonnes problématiques (géo complexes, etc.)
    if drop_columns:
        for col in drop_columns:
            col_clean = clean_column_name(col)
            if col_clean in df.columns:
                df = df.drop(columns=[col_clean])
                print(f"  🗑️ Colonne supprimée: {col_clean} (type complexe)")
    
    # Convertir les colonnes avec des dicts/lists en strings (pour les colonnes géo restantes)
    for col in df.columns:
        if df[col].dtype == 'object':
            # Vérifier si c'est une colonne avec des dicts/lists
            sample = df[col].dropna().head(1)
            if len(sample) > 0 and isinstance(sample.iloc[0], (dict, list)):
                df[col] = df[col].apply(lambda x: json.dumps(x) if isinstance(x, (dict, list)) else x)
                print(f"  📝 Colonne convertie en JSON string: {col}")

    # Stamp la fraîcheur du sync : permet à dbt source freshness de détecter
    # un sync cassé (cf. pipeline/models/staging/sources.yml). UTC, naive
    # accepté par BQ comme TIMESTAMP.
    df["_synced_at"] = pd.Timestamp.utcnow().tz_localize(None)
    
    # Afficher le mapping des colonnes modifiées
    print(f"  📝 Colonnes nettoyées:")
    changed = [(old, new) for old, new in new_columns.items() if old != new]
    if changed:
        for old, new in changed[:5]:  # Limiter l'affichage
            print(f"      {old} → {new}")
        if len(changed) > 5:
            print(f"      ... et {len(changed) - 5} autres")
    
    # Initialiser le client BigQuery
    client = bigquery.Client(project=project_id)
    
    # Créer le dataset s'il n'existe pas
    dataset_ref = f"{project_id}.{dataset_id}"
    try:
        client.get_dataset(dataset_ref)
    except Exception:
        dataset = bigquery.Dataset(dataset_ref)
        dataset.location = "EU"
        client.create_dataset(dataset)
        print(f"  ✓ Dataset {dataset_id} créé")
    
    # Upload vers BigQuery
    table_ref = f"{project_id}.{dataset_id}.{table_name}"
    print(f"  📤 Upload vers {table_ref}...")
    
    job_config = bigquery.LoadJobConfig(
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )
    
    try:
        job = client.load_table_from_dataframe(df, table_ref, job_config=job_config)
        job.result()  # Attendre la fin
        
        # Vérifier
        table = client.get_table(table_ref)
        print(f"  ✓ {table.num_rows:,} lignes chargées dans {table_name}")
        return table.num_rows
    except Exception as e:
        print(f"  ❌ Erreur upload: {e}")
        # Essayer avec CSV comme fallback
        print(f"  🔄 Tentative upload via CSV...")
        try:
            import io
            csv_buffer = io.StringIO()
            df.to_csv(csv_buffer, index=False)
            csv_buffer.seek(0)
            
            job_config = bigquery.LoadJobConfig(
                write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
                source_format=bigquery.SourceFormat.CSV,
                skip_leading_rows=1,
                autodetect=True,
            )
            job = client.load_table_from_file(csv_buffer, table_ref, job_config=job_config)
            job.result()
            
            table = client.get_table(table_ref)
            print(f"  ✓ {table.num_rows:,} lignes chargées via CSV dans {table_name}")
            return table.num_rows
        except Exception as e2:
            print(f"  ❌ Erreur upload CSV: {e2}")
            return 0


# =============================================================================
# Synchronisation
# =============================================================================

def sync_source(source_name: str, dry_run: bool = False) -> dict:
    """
    Synchronise une source de données.
    
    Args:
        source_name: Nom de la source (clé dans DATASETS)
        dry_run: Si True, télécharge sans uploader
    
    Returns:
        dict avec stats de synchronisation
    """
    if source_name not in DATASETS:
        raise ValueError(f"Source inconnue: {source_name}. Sources disponibles: {list(DATASETS.keys())}")
    
    config = DATASETS[source_name]
    dataset_id = config["dataset_id"]
    table_name = dataset_id_to_table_name(dataset_id)  # Nom exact OpenData en snake_case
    description = config["description"]
    year_column = config["year_column"]
    drop_columns = config.get("drop_columns", [])
    
    print(f"\n{'='*60}")
    print(f"📊 {source_name.upper()}: {description}")
    print(f"{'='*60}")
    
    # Récupérer les infos du dataset
    try:
        info = get_dataset_info(dataset_id)
        modified = info.get("metas", {}).get("default", {}).get("modified", "N/A")
        print(f"  Dernière MAJ: {modified}")
    except Exception as e:
        print(f"  ⚠️ Impossible de récupérer les métadonnées: {e}")
    
    # Années disponibles
    years = []
    if year_column:
        try:
            years = get_available_years(dataset_id, year_column)
            print(f"  Années disponibles: {years}")
        except Exception as e:
            print(f"  ⚠️ Impossible de récupérer les années: {e}")
    else:
        print(f"  ℹ️ Pas de colonne année (sera parsé depuis 'publication')")
    
    # Télécharger
    df = download_dataset(dataset_id)
    
    if df.empty:
        return {"source": source_name, "rows": 0, "status": "empty"}
    
    # Upload (sauf dry_run)
    if dry_run:
        print(f"  🔸 DRY RUN - pas d'upload")
        rows = len(df)
    else:
        rows = upload_to_bigquery(df, table_name, drop_columns=drop_columns)
    
    return {
        "source": source_name,
        "table": table_name,
        "rows": rows,
        "years": years,
        "status": "success",
    }


def sync_all(dry_run: bool = False) -> list[dict]:
    """Synchronise toutes les sources."""
    results = []
    
    print("\n" + "="*60)
    print("🔄 SYNCHRONISATION PARIS OPEN DATA → BIGQUERY")
    print("="*60)
    print(f"  Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  Projet: {PROJECT_ID}")
    print(f"  Dataset: {DATASET_ID}")
    if dry_run:
        print("  ⚠️ MODE DRY RUN - pas d'upload")
    
    for source_name in DATASETS.keys():
        try:
            result = sync_source(source_name, dry_run=dry_run)
            results.append(result)
        except Exception as e:
            print(f"  ❌ Erreur pour {source_name}: {e}")
            results.append({
                "source": source_name,
                "rows": 0,
                "status": "error",
                "error": str(e),
            })
    
    # Résumé
    print("\n" + "="*60)
    print("📋 RÉSUMÉ DE LA SYNCHRONISATION")
    print("="*60)
    
    total_rows = 0
    for r in results:
        status_icon = "✓" if r["status"] == "success" else "❌" if r["status"] == "error" else "○"
        rows = r.get("rows", 0)
        total_rows += rows
        years = r.get("years", [])
        years_str = f" ({min(years)}-{max(years)})" if years else ""
        print(f"  {status_icon} {r['source']}: {rows:,} lignes{years_str}")
    
    print(f"\n  TOTAL: {total_rows:,} lignes")
    
    return results


def list_sources():
    """Liste les sources disponibles avec leurs infos."""
    print("\n" + "="*60)
    print("📋 SOURCES DISPONIBLES")
    print("="*60)
    
    for name, config in DATASETS.items():
        table_name = dataset_id_to_table_name(config['dataset_id'])
        print(f"\n  {name}")
        print(f"    Description: {config['description']}")
        print(f"    Dataset ID: {config['dataset_id']}")
        print(f"    Table BQ: raw.{table_name}")
        
        # Récupérer les années si possible
        try:
            years = get_available_years(config["dataset_id"], config["year_column"])
            print(f"    Années: {min(years)}-{max(years)} ({len(years)} années)")
        except Exception:
            print(f"    Années: (impossible à récupérer)")


def check_data_availability() -> dict:
    """
    Vérifie la disponibilité des données par année.
    
    Retourne un dict avec le statut de chaque année:
    - COMPLET: toutes les sources disponibles
    - PARTIEL: certaines sources manquantes
    - BUDGET_SEUL: uniquement le budget principal
    """
    print("\n" + "="*60)
    print("🔍 VÉRIFICATION DISPONIBILITÉ DES DONNÉES")
    print("="*60)
    
    # Collecter les années par source
    years_by_source = {}
    for name, config in DATASETS.items():
        year_column = config.get("year_column")
        if not year_column:
            print(f"  {name}: (année non disponible - parsé depuis publication)")
            years_by_source[name] = set()
            continue
        try:
            years = get_available_years(config["dataset_id"], year_column)
            years_by_source[name] = set(years)
            print(f"  {name}: {min(years)}-{max(years)}")
        except Exception as e:
            print(f"  {name}: ❌ {e}")
            years_by_source[name] = set()
    
    # Déterminer le statut par année
    all_years = set()
    for years in years_by_source.values():
        all_years.update(years)
    
    availability = {}
    for year in sorted(all_years, reverse=True):
        has_budget = year in years_by_source.get("budget_execute", set())
        has_subventions = year in years_by_source.get("associations", set())
        has_autorisations = year in years_by_source.get("ap_execute", set())
        has_arrondissements = year in years_by_source.get("arrondissements", set())
        
        if has_budget and has_subventions and has_autorisations and has_arrondissements:
            status = "COMPLET"
        elif has_budget and has_subventions:
            status = "PARTIEL"
        elif has_budget:
            status = "BUDGET_SEUL"
        else:
            status = "INCOMPLET"
        
        availability[year] = {
            "status": status,
            "has_budget": has_budget,
            "has_subventions": has_subventions,
            "has_autorisations": has_autorisations,
            "has_arrondissements": has_arrondissements,
        }
    
    # Afficher le résumé
    print("\n  Année   │ Budget │ Subv │ AP/CP │ Arr. │ Statut")
    print("  ────────┼────────┼──────┼───────┼──────┼────────")
    for year in sorted(availability.keys(), reverse=True):
        a = availability[year]
        b = "✓" if a["has_budget"] else "✗"
        s = "✓" if a["has_subventions"] else "✗"
        ap = "✓" if a["has_autorisations"] else "✗"
        ar = "✓" if a["has_arrondissements"] else "✗"
        print(f"  {year}    │   {b}    │  {s}   │   {ap}   │  {ar}   │ {a['status']}")
    
    return availability


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Synchronisation Paris Open Data → BigQuery",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exemples:
    # Synchroniser toutes les sources
    python scripts/sync_opendata.py
    
    # Synchroniser une source spécifique
    python scripts/sync_opendata.py --source budget_execute
    
    # Mode dry run (télécharge sans uploader)
    python scripts/sync_opendata.py --dry-run
    
    # Vérifier la disponibilité des données
    python scripts/sync_opendata.py --check
        """
    )
    parser.add_argument(
        "--source",
        choices=list(DATASETS.keys()),
        help="Source spécifique à synchroniser"
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="Lister les sources disponibles"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Vérifier la disponibilité des données par année"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Télécharger sans uploader vers BigQuery"
    )
    
    args = parser.parse_args()

    print("\n⚠️  DEPRECATED: sync_opendata.py est remplacé par "
          "`python scripts/sync/sync_city.py paris` (ingester ODS générique).\n"
          "   Parité prouvée par scripts/sync/verify_ods_parity.py. "
          "Ce script sera supprimé prochainement.\n")

    if args.list:
        list_sources()
        return
    
    if args.check:
        check_data_availability()
        return
    
    if args.source:
        sync_source(args.source, dry_run=args.dry_run)
    else:
        sync_all(dry_run=args.dry_run)
    
    print("\n✅ Synchronisation terminée !")
    print("\nProchaines étapes:")
    print("  1. dbt run                           # Transformer les données")
    print("  2. python scripts/enrich_geo_data.py # Enrichir via LLM")
    print("  3. python scripts/export_sankey_data.py # Exporter pour frontend")


if __name__ == "__main__":
    main()
