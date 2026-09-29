#!/usr/bin/env python3
"""
Generic Opendatasoft (ODS Explore API v2.1) → BigQuery sync (protocol adapter).

Reads a city YAML config (e.g. `pipeline/configs/cities/paris.yaml`), resolves
each `ods_dataset` source and loads the FULL dataset into BigQuery
`raw.{target_table}` (WRITE_TRUNCATE). ODS is the platform Paris and most
French cities publish on (opendata.paris.fr, data.ampmetropole.fr,
data.economie.gouv.fr, data.ofgl.fr all speak the same Explore API), so one
generic ingester keyed on a `portal` domain replaces the per-portal scripts.

Protocol facts this adapter encodes:
  - Full export via `/api/explore/{api_version}/catalog/datasets/{id}/exports/json`
    with `limit=-1` (no pagination cap — the export endpoint streams the whole
    dataset). These municipal-finance datasets are modest (tens of thousands of
    rows); the multi-million-row paging machinery in sync_socrata.py is not
    needed here.
  - Column names are cleaned to BigQuery-safe snake_case (accents stripped,
    special chars → `_`, collapsed) — identical to the transform the legacy
    Paris `sync_opendata.py` used, so raw tables stay schema-stable across the
    migration.
  - Nested geo columns (dict/list values) are JSON-serialised to STRING; a
    source may `drop_columns` heavy geo shapes it doesn't need (e.g.
    `geo_shape`).
  - `_synced_at` (naive UTC TIMESTAMP) is stamped on every row so dbt source
    freshness can detect a broken sync.

Raw fidelity: this adapter is deliberately a faithful port of the legacy
per-source Paris loader (`load_table_from_dataframe`, BQ type inference), NOT
the all-STRING convention of sync_socrata.py. That keeps the existing Paris
`raw.*` schemas byte/structurally identical through the config migration; the
raw→canonical mapping stays in the dbt staging layer. `map_to`/`field_map` in
the YAML are declarative provenance for the (future) country-profile layer and
are NOT applied here — like every other generic ingester, this one loads raw
faithfully and lets staging do the mapping.

Catalog snapshot: every run also refreshes `raw.<city>_catalog` — one row
per (dataset, field) from `/catalog/datasets/{id}` (title, page URL,
license, publisher, `modified`). It is the provenance source of truth read
by stg_<city>_catalog → core_<city>_source_catalog, so no model hardcodes a
dataset URL. A source may declare `catalog_only: true` when its rows are
loaded by a dedicated script (dette-garantie's per-year refine): it gets a
catalog row but no data load here.

Usage:
    python sync_ods_dataset.py --city paris                       # all ods sources + catalog
    python sync_ods_dataset.py --city paris --catalog-only        # metadata snapshot only
    python sync_ods_dataset.py --city paris --source budget_principal
    python sync_ods_dataset.py --city paris --dry-run             # plan only
    python sync_ods_dataset.py --city paris --raw-dataset raw_parity  # shadow load
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sys
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import requests
import yaml
from google.cloud import bigquery

PIPELINE_ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(PIPELINE_ROOT / "scripts"))

from utils.logger import Logger  # noqa: E402

PROJECT_ID = "open-data-france-484717"
RAW_DATASET_DEFAULT = "raw"
DEFAULT_API_VERSION = "v2.1"
REQUEST_TIMEOUT_S = 300


def load_city_config(city_slug: str) -> dict:
    cfg_path = PIPELINE_ROOT / "configs" / "cities" / f"{city_slug}.yaml"
    if not cfg_path.exists():
        raise FileNotFoundError(f"city config not found: {cfg_path}")
    with open(cfg_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def ods_sources(config: dict) -> list[dict]:
    """ods_dataset sources whose DATA this adapter loads. `catalog_only: true`
    entries are excluded here (their rows come from another loader, e.g.
    sync_dette_garantie.py's per-year refine) but still get a catalog row."""
    return [
        s for s in config.get("sources", [])
        if s.get("type") == "ods_dataset" and not s.get("catalog_only")
    ]


def catalog_sources(config: dict) -> list[dict]:
    """Every ods_dataset source, catalog_only ones included."""
    return [s for s in config.get("sources", []) if s.get("type") == "ods_dataset"]


def catalog_table_name(config: dict) -> str:
    return config.get("ods", {}).get("catalog_table") or f"{config['city_slug']}_catalog"


def clean_column_name(name: str) -> str:
    """BigQuery-safe snake_case. Identical transform to the legacy
    sync_opendata.py so migrated raw tables keep the same column names:
    strip accents (NFD), lowercase, collapse special chars → `_`, trim."""
    name = unicodedata.normalize("NFD", name)
    name = "".join(c for c in name if unicodedata.category(c) != "Mn")
    name = name.lower()
    name = re.sub(r"[\s/\(\)\-\.]+", "_", name)
    name = re.sub(r"[^a-z0-9_]", "_", name)
    name = re.sub(r"_+", "_", name)
    return name.strip("_")


def dataset_id_to_table_name(dataset_id: str) -> str:
    """Default raw table name when a source omits `target_table`: the ODS
    dataset id in snake_case (dashes → underscores). Matches the legacy
    naming convention (raw table = dataset_id snake_case)."""
    return dataset_id.replace("-", "_").rstrip("_")


def resolve_portal(config: dict, source: dict) -> tuple[str, str]:
    """(domain, api_version). Per-source `portal` wins; otherwise the city's
    top-level `ods` block; api_version defaults to v2.1."""
    block = config.get("ods", {}) or {}
    domain = source.get("portal") or block.get("domain")
    if not domain:
        raise ValueError(
            f"source '{source.get('id')}' has no `portal` and config has no "
            "top-level `ods.domain`"
        )
    api_version = source.get("api_version") or block.get("api_version") or DEFAULT_API_VERSION
    return domain, api_version


_RESOLVES: dict[str, bool] = {}


def _resolves(host: str) -> bool:
    if host not in _RESOLVES:
        try:
            socket.getaddrinfo(host, 443)
            _RESOLVES[host] = True
        except socket.gaierror:
            _RESOLVES[host] = False
    return _RESOLVES[host]


def resolve_fetch_portal(config: dict, source: dict) -> tuple[str, str]:
    """resolve_portal, for the HTTP calls. When the portal's name does not
    resolve and the config names the platform's own address (`ods.domain_fallback`,
    or `portal_fallback` next to a source's own `portal`), that address. The
    catalog keeps the configured name: the links readers see do not follow an
    outage. (2026-09-23: opendata.paris.fr NXDOMAIN everywhere, the same
    portal answering at parisdata.opendatasoft.com.)"""
    domain, api_version = resolve_portal(config, source)
    block = config.get("ods", {}) or {}
    fallback = source.get("portal_fallback") if source.get("portal") else block.get("domain_fallback")
    if fallback and not _resolves(domain):
        if domain not in _WARNED:
            print(f"  ! {domain} ne résout pas : le portail est lu à {fallback}")
            _WARNED.add(domain)
        return fallback, api_version
    return domain, api_version


_WARNED: set[str] = set()


def download_dataset(
    domain: str, api_version: str, dataset_id: str, log: Logger,
    where: str | None = None, select: str | None = None,
) -> pd.DataFrame:
    """Full dataset via the ODS export endpoint (no pagination cap).

    `where` / `select` are ODSQL clauses the export endpoint honours (verified
    live on opendata.vancouver.ca 2026-09-12: a `where` cut 1.55 M rows to
    the requested slice and `select` returned only the named columns). They
    are PROTOCOL features, declared per source in the city YAML, so a large
    dataset can be pulled by year or trimmed of columns it does not need —
    the raw table still holds exactly what the portal returned for that
    clause. Absent both, behaviour is unchanged: the whole dataset."""
    url = f"https://{domain}/api/explore/{api_version}/catalog/datasets/{dataset_id}/exports/json"
    params: dict = {"limit": -1}
    if where:
        params["where"] = where
    if select:
        params["select"] = select
    resp = requests.get(url, params=params, timeout=REQUEST_TIMEOUT_S, stream=True)
    resp.raise_for_status()
    data = resp.json()
    if not data:
        log.warning("no rows returned", extra=dataset_id)
        return pd.DataFrame()
    return pd.DataFrame(data)


def prepare_dataframe(df: pd.DataFrame, drop_columns: list[str], synced_at: datetime, log: Logger) -> pd.DataFrame:
    """Clean column names, drop heavy geo columns, JSON-serialise nested
    values, stamp `_synced_at`. Mirrors the legacy loader exactly."""
    df = df.rename(columns={c: clean_column_name(c) for c in df.columns})

    for col in drop_columns or []:
        col_clean = clean_column_name(col)
        if col_clean in df.columns:
            df = df.drop(columns=[col_clean])
            log.info("dropped column", extra=f"{col_clean} (complex geo)")

    for col in df.columns:
        if df[col].dtype == "object":
            sample = df[col].dropna().head(1)
            if len(sample) > 0 and isinstance(sample.iloc[0], (dict, list)):
                # Match the legacy loader byte-for-byte: default json.dumps
                # (ensure_ascii=True) so accented values escape to \uXXXX
                # exactly as the existing raw tables were written. Do NOT
                # "improve" to ensure_ascii=False — that silently changes the
                # raw content vs every prior sync.
                df[col] = df[col].apply(
                    lambda x: json.dumps(x) if isinstance(x, (dict, list)) else x
                )
                log.info("serialised column to JSON string", extra=col)

    # Naive UTC (BQ accepts as TIMESTAMP), same as the legacy loader.
    df["_synced_at"] = pd.Timestamp(synced_at).tz_localize(None)
    return df


def load_dataframe_to_bigquery(
    client: bigquery.Client, df: pd.DataFrame, raw_dataset: str, table_id: str, log: Logger
) -> int:
    if df.empty:
        log.warning("empty dataframe, skipping load", extra=table_id)
        return 0
    table_ref = f"{PROJECT_ID}.{raw_dataset}.{table_id}"
    job_config = bigquery.LoadJobConfig(
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )
    job = client.load_table_from_dataframe(df, table_ref, job_config=job_config)
    job.result()
    n_rows = int(client.get_table(table_ref).num_rows)
    log.success(f"loaded {n_rows:,} rows", extra=table_ref)
    return n_rows


# ---------------------------------------------------------------------------
# catalog snapshot (provenance source of truth — mirrors sync_socrata.py)
# ---------------------------------------------------------------------------

def fetch_dataset_metadata(domain: str, api_version: str, dataset_id: str) -> dict:
    """`/catalog/datasets/{id}` — title, license, publisher, `modified`
    (portal refresh timestamp), records_count and the field list."""
    url = f"https://{domain}/api/explore/{api_version}/catalog/datasets/{dataset_id}"
    resp = requests.get(url, timeout=REQUEST_TIMEOUT_S)
    resp.raise_for_status()
    return resp.json()


def build_catalog_rows(config: dict, sources: list[dict], metas: dict[str, dict]) -> list[dict]:
    """One row per (dataset, field): dataset-level provenance (title, page
    URL, license, publisher, `modified` → rows_updated_at) + per-field
    metadata. All values are strings (typed in stg_<city>_catalog)."""
    out: list[dict] = []
    for source in sources:
        domain, _ = resolve_portal(config, source)
        meta = metas[source["id"]]
        default = (meta.get("metas") or {}).get("default") or {}
        dataset_id = meta.get("dataset_id") or source["dataset_id"]
        base = {
            "source_id": source["id"],
            "dataset_id": dataset_id,
            "dataset_title": default.get("title"),
            "dataset_page_url": f"https://{domain}/explore/dataset/{dataset_id}/",
            "domain": domain,
            "portal_name": config.get("ods", {}).get("portal_name"),
            "publisher": default.get("publisher"),
            "license_title": default.get("license"),
            "license_url": default.get("license_url"),
            "theme": "; ".join(default.get("theme") or []) or None,
            "rows_updated_at": default.get("modified"),
            "data_processed_at": default.get("data_processed"),
            "records_count": (
                str(default["records_count"]) if default.get("records_count") is not None else None
            ),
        }
        fields = meta.get("fields") or [{}]
        for position, field in enumerate(fields):
            out.append({
                **base,
                "column_field_name": field.get("name"),
                "column_display_name": field.get("label"),
                "column_data_type": field.get("type"),
                "column_description": field.get("description"),
                "column_position": str(position),
            })
    return out


def load_catalog(client: bigquery.Client, rows: list[dict], raw_dataset: str,
                 table_id: str, synced_at: datetime, log: Logger) -> None:
    if not rows:
        raise ValueError("no catalog rows to load")
    field_names = [k for k in rows[0].keys()]
    schema = [bigquery.SchemaField(n, "STRING") for n in field_names]
    schema.append(bigquery.SchemaField("_synced_at", "TIMESTAMP"))
    stamp = synced_at.isoformat()
    for r in rows:
        r["_synced_at"] = stamp
    table_ref = f"{PROJECT_ID}.{raw_dataset}.{table_id}"
    job_config = bigquery.LoadJobConfig(
        schema=schema, write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE
    )
    client.load_table_from_json(rows, table_ref, job_config=job_config).result()
    log.success(f"loaded {len(rows):,} catalog rows", extra=table_ref)


def sync_catalog(client: bigquery.Client, config: dict, raw_dataset: str, log: Logger) -> int:
    sources = catalog_sources(config)
    log.section(f"Catalog snapshot ({len(sources)} dataset(s))")
    metas = {}
    for source in sources:
        domain, api_version = resolve_fetch_portal(config, source)
        metas[source["id"]] = fetch_dataset_metadata(domain, api_version, source["dataset_id"])
        log.info("metadata", extra=f"{source['id']} · modified={metas[source['id']].get('metas', {}).get('default', {}).get('modified')}")
    rows = build_catalog_rows(config, sources, metas)
    load_catalog(client, rows, raw_dataset, catalog_table_name(config), datetime.now(timezone.utc), log)
    return len(rows)


def get_bigquery_client() -> bigquery.Client:
    """Same credential resolution as the other generic ingesters."""
    creds_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not creds_path:
        for p in [
            Path.home() / ".config" / "gcloud" / "application_default_credentials.json",
            PIPELINE_ROOT.parent / "credentials.json",
            PIPELINE_ROOT / "credentials.json",
        ]:
            if p.exists():
                os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = str(p)
                break
    return bigquery.Client(project=PROJECT_ID)


def sync_source(client: bigquery.Client, config: dict, source: dict, raw_dataset: str, log: Logger) -> dict:
    source_id = source["id"]
    dataset_id = source["dataset_id"]
    table_id = source.get("target_table") or dataset_id_to_table_name(dataset_id)
    domain, api_version = resolve_fetch_portal(config, source)

    log.section(f"Source: {source_id} ({dataset_id})")
    log.info("description", extra=source.get("description", ""))
    log.info("portal", extra=f"{domain} ({api_version}) → {raw_dataset}.{table_id}")

    if source.get("where") or source.get("select"):
        log.info("export clause", extra=f"where={source.get('where')!r} select={source.get('select')!r}")
    df = download_dataset(
        domain, api_version, dataset_id, log,
        where=source.get("where"), select=source.get("select"),
    )
    log.info("downloaded", extra=f"{len(df):,} rows, {len(df.columns)} columns")
    df = prepare_dataframe(df, source.get("drop_columns", []), datetime.now(timezone.utc), log)
    rows = load_dataframe_to_bigquery(client, df, raw_dataset, table_id, log)
    return {"source_id": source_id, "table": table_id, "rows": rows}


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--city", required=True, help="City slug (e.g. paris)")
    parser.add_argument("--source", help="Source id to sync (default: all ods_dataset sources)")
    parser.add_argument("--raw-dataset", dest="raw_dataset",
                        help="Override the destination BQ dataset (e.g. raw_parity for a shadow load)")
    parser.add_argument("--dry-run", action="store_true", help="Plan only, don't fetch or load")
    parser.add_argument("--skip-catalog", action="store_true",
                        help="Don't refresh raw.<city>_catalog (portal metadata snapshot)")
    parser.add_argument("--catalog-only", action="store_true",
                        help="Only refresh raw.<city>_catalog, load no dataset")
    args = parser.parse_args()

    log = Logger("sync_ods")
    log.header(f"Opendatasoft → BigQuery sync — city={args.city}")

    config = load_city_config(args.city)
    raw_dataset = args.raw_dataset or config.get("bq_raw_dataset", RAW_DATASET_DEFAULT)

    sources = ods_sources(config)
    if args.catalog_only:
        sources = []
    elif args.source:
        sources = [s for s in sources if s["id"] == args.source]
        if not sources:
            catalog_only = [s for s in catalog_sources(config) if s["id"] == args.source]
            if catalog_only:
                log.info("catalog-only source", extra=f"{args.source}: data loaded elsewhere, refreshing catalog only")
            else:
                log.error(f"source '{args.source}' not found in {args.city}.yaml")
                return 2

    log.info("sources to sync", extra=f"{len(sources)} source(s) → dataset '{raw_dataset}'")

    if args.dry_run:
        log.section("Dry run — would sync:")
        for s in sources:
            domain, api_version = resolve_fetch_portal(config, s)
            table_id = s.get("target_table") or dataset_id_to_table_name(s["dataset_id"])
            log.info("would load", extra=f"{domain}/{s['dataset_id']} → {raw_dataset}.{table_id}")
        if not args.skip_catalog:
            log.info("would snapshot catalog", extra=f"{len(catalog_sources(config))} dataset(s) → {raw_dataset}.{catalog_table_name(config)}")
        return 0

    log.section("BigQuery client")
    client = get_bigquery_client()
    log.success("connected", extra=PROJECT_ID)

    summaries = []
    failures = 0
    for source in sources:
        try:
            summaries.append(sync_source(client, config, source, raw_dataset, log))
        except Exception as e:
            log.error(f"sync failed: {source['id']}", extra=str(e))
            failures += 1

    if not args.skip_catalog:
        try:
            sync_catalog(client, config, raw_dataset, log)
        except Exception as e:
            log.error("catalog snapshot failed", extra=str(e))
            failures += 1

    log.section("Summary")
    total_rows = sum(s["rows"] for s in summaries)
    log.info("tables loaded", extra=str(len(summaries)))
    log.info("rows loaded", extra=f"{total_rows:,}")
    if failures:
        log.error(f"{failures} failure(s)")
        return 1
    log.success("sync OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
