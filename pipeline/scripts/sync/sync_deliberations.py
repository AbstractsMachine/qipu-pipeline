#!/usr/bin/env python3
"""
Sync Conseil de Paris deliberations (subventions_delibs/session_*.json) → BQ.

Source = les session_*.json déjà produits par scrape_deliberations.py +
enrich_deliberations_*. Cette commande fait le pont vers BigQuery en
chargeant 2 tables raw : sessions (métadonnées) et articles (subventions
individuelles extraites). Les délibs (titres) sont rattachés aux
articles via delib_id ; on n'a pas besoin de table dédiée delibs car
title/direction sont reportés au grain article.

Une fois cette table peuplée, la chaîne dbt prend le relais et
`export_deliberations.py` reproduit le JSON. scrape_deliberations.py +
enrich_deliberations_* peuvent alors écrire dans `pipeline/cache/delibs/`
(interne) plutôt que dans public/data — la version publiée est produite
par l'export.

Usage:
    python pipeline/scripts/sync/sync_deliberations.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pandas as pd
from google.cloud import bigquery

sys.path.insert(0, str(Path(__file__).parent.parent))
from utils.logger import Logger

PROJECT_ID = "open-data-france-484717"
RAW_DATASET = "raw"
ROOT = Path(__file__).resolve().parents[3]
# Source = cache interne alimenté par scrape_deliberations + enrich_deliberations_*
DELIBS_DIR = ROOT / "pipeline" / "cache" / "delibs" / "sessions"


def collect(logger: Logger) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    sessions: list[dict] = []
    delibs: list[dict] = []
    articles: list[dict] = []
    for path in sorted(DELIBS_DIR.glob("session_*.json")):
        d = json.loads(path.read_text(encoding="utf-8"))
        session_id = d.get("session_id")
        if session_id is None:
            continue
        sessions.append({
            "session_id": int(session_id),
            "generated_at": d.get("generated_at"),
            "source": d.get("source"),
            "nb_delibs": int(d.get("nb_delibs") or 0),
            "nb_articles": int(d.get("nb_articles") or 0),
        })
        for db in d.get("delibs", []) or []:
            delibs.append({
                "session_id": int(session_id),
                "delib_id": db.get("delib_id"),
                "id_entite": db.get("id_entite"),
                "title": db.get("title"),
                "direction_id": db.get("direction_id"),
                "direction_name": db.get("direction_name"),
            })
        for art in d.get("articles", []) or []:
            articles.append({
                "session_id": int(session_id),
                "delib_id": art.get("delib_id"),
                "direction_id": art.get("direction_id"),
                "direction_name": art.get("direction_name"),
                "article_num": art.get("article_num"),
                "beneficiary": art.get("beneficiary"),
                "siret": art.get("siret"),
                "amount_eur": float(art.get("amount_eur")) if art.get("amount_eur") is not None else None,
                "amount_raw": art.get("amount_raw"),
                "motif": art.get("motif"),
                "dossier": art.get("dossier"),
            })
        logger.info(f"  session_{session_id}: {len(d.get('delibs') or [])} delibs / {len(d.get('articles') or [])} articles")
    return pd.DataFrame(sessions), pd.DataFrame(delibs), pd.DataFrame(articles)


def upload(df: pd.DataFrame, table: str, client: bigquery.Client, logger: Logger) -> None:
    table_ref = f"{PROJECT_ID}.{RAW_DATASET}.{table}"
    # WRITE_TRUNCATE remplace la table. Un DataFrame vide n'a pas de colonnes :
    # BigQuery écrase alors la table prod par une coquille à une colonne
    # (`loaded_at`) et tout le staging casse (« Unrecognized name: session_id »).
    # C'est arrivé le 2026-09-08 en CI, où le cache source n'existe pas.
    # Zéro ligne n'est jamais une donnée à publier : on refuse.
    if df.empty:
        raise SystemExit(
            f"✗ {table}: 0 ligne à charger — refus d'écraser la table prod. "
            f"Source attendue : {DELIBS_DIR} (vide ou absente ?)"
        )
    job_config = bigquery.LoadJobConfig(
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        autodetect=True,
    )
    logger.info(f"Upload → {table_ref} ({len(df):,} rows)")
    df["loaded_at"] = pd.Timestamp.utcnow()
    job = client.load_table_from_dataframe(df, table_ref, job_config=job_config)
    job.result()


def main() -> None:
    logger = Logger("sync_deliberations")
    logger.header("Sync Conseil de Paris deliberations → BigQuery")
    # Le cache vient d'un scrape fait en session (scrape_deliberations.py) et vit
    # sous pipeline/cache/, ignoré par git : en CI il n'existe pas. Ce n'est pas
    # une erreur — c'est « rien de nouveau ». Les tables raw gardent leur contenu
    # et la chaîne dbt continue dessus. On le dit, et on sort proprement.
    if not DELIBS_DIR.is_dir() or not any(DELIBS_DIR.glob("session_*.json")):
        logger.info(
            f"Source absente ({DELIBS_DIR}) — skip, les tables raw deliberations_* "
            f"gardent leur contenu précédent."
        )
        return
    sessions_df, delibs_df, articles_df = collect(logger)
    logger.info(
        f"Total: {len(sessions_df)} sessions · {len(delibs_df)} delibs · {len(articles_df)} articles"
    )
    # Tout ou rien : les trois tables décrivent le même corpus. On vérifie les
    # trois AVANT le premier upload pour ne jamais laisser prod à moitié écrasée.
    for name, df in (("sessions", sessions_df), ("delibs", delibs_df), ("articles", articles_df)):
        if df.empty:
            raise SystemExit(f"✗ {name}: 0 ligne — refus de charger (source : {DELIBS_DIR}).")
    client = bigquery.Client(project=PROJECT_ID)
    upload(sessions_df, "deliberations_sessions_paris", client, logger)
    upload(delibs_df, "deliberations_delibs_paris", client, logger)
    upload(articles_df, "deliberations_articles_paris", client, logger)
    logger.success("Done")


if __name__ == "__main__":
    main()
