#!/usr/bin/env python3
"""
Generic Socrata/SODA → BigQuery sync (protocol adapter).

Reads a country YAML config (e.g. `pipeline/configs/countries/us.yaml`),
resolves each `socrata` source and loads the FULL dataset into BigQuery
`raw.{target_table}` (WRITE_TRUNCATE). The protocol block (default `datasf`)
carries the domain, catalog table and paging defaults; each source carries
the dataset 4x4 id and a `mode`:

  - `paged-json`: `/resource/<id>.json` with $limit/$offset (+ stable
    $order — `:id`). Pages are buffered to a local NDJSON.gz file, then
    loaded in ONE gzipped load job. Suitable up to ~1M rows.
  - `bulk-csv`  : CSV pulled in large pages (`/resource/<id>.csv`,
    csv_page_size rows each, default 500k, stable `$order=:id`), buffered
    to ONE local csv.gz, then one BigQuery CSV load job into a temp table
    + CTAS to stamp `_synced_at`. The sane path for multi-million-row
    datasets (SF vouchers = 8.07M rows — docs/us/API-RECON.md §A.3).
    Why pages and not the one-shot `/api/views/<id>/rows.csv` export: that
    stream DROPS mid-transfer on long pulls (verified live 2026-07-16 —
    IncompleteRead after 13 min) and supports neither Range nor resume, so
    one hiccup costs the whole multi-GB download. Failed pages retry
    individually. The /resource CSV endpoint also uses API field names as
    headers (the views export uses display names — both are mapped).

  Everything is uploaded GZIPPED (BigQuery auto-detects gzip on local
  media uploads — verified live 2026-07-16): measured residential uplink
  was ~60 KB/s, which makes uncompressed multi-GB uploads unworkable
  (~15 min for a single 40 MB page). Compression turns the 8M-row voucher
  load from "days" into "an hour or two".

Protocol facts this adapter encodes (docs/us/API-RECON.md §A.6, verified
live 2026-07-15/16):
  - SODA JSON records OMIT keys whose value is null → the authoritative
    column list comes from `/api/views/<id>.json` metadata, never from rows.
  - Bulk CSV headers are DISPLAY names ("Supplier & Other Non-Supplier
    Payees") → mapped back to API field names via the same metadata.
  - Numbers arrive as strings; JSON is parsed with parse_float=str /
    parse_int=str so raw stays byte-faithful. Text dates come in mixed
    formats — kept as-is, typed once in stg.
  - Anonymous access works (pooled throttle); an INVALID X-App-Token is
    worse than none (403) — set SOCRATA_APP_TOKEN env var to use one.

Raw tables get an all-STRING schema + `_synced_at` (TIMESTAMP). Each run
also snapshots every dataset's `/api/views/<id>.json` metadata (name,
description, rowsUpdatedAt, columns) into the protocol catalog table
(`raw.us_sf_catalog`) — the provenance source of truth for stg/marts/exports.

Usage:
    python sync_socrata.py us                          # all socrata sources + catalog
    python sync_socrata.py us --source sf_budget       # one source (+ catalog)
    python sync_socrata.py us --skip-catalog           # skip catalog snapshot
    python sync_socrata.py us --dry-run                # plan only
    python sync_socrata.py us --block datasf           # explicit protocol block
    python sync_socrata.py us --block ca_sco           # California State Controller (ByTheNumbers)
"""

from __future__ import annotations

import argparse
import csv
import gzip
import json
import os
import re
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
import yaml
from google.cloud import bigquery

PIPELINE_ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(PIPELINE_ROOT / "scripts"))

from utils.logger import Logger  # noqa: E402

PROJECT_ID = "open-data-france-484717"
RAW_DATASET_DEFAULT = "raw"
PAGE_SIZE_DEFAULT = 50000
CSV_PAGE_SIZE_DEFAULT = 500000
REQUEST_TIMEOUT_S = 600
MAX_RETRIES = 4


def request_headers() -> dict:
    """Anonymous works; an INVALID X-App-Token → 403 (API-RECON §A.6), so
    only send a token when one is explicitly configured."""
    token = os.environ.get("SOCRATA_APP_TOKEN")
    return {"X-App-Token": token} if token else {}


def get_with_retry(url: str, params: dict | None = None, log: Logger | None = None,
                   stream: bool = False) -> requests.Response:
    """GET with linear-backoff retries (same pattern as sync_fiscaldata.py).

    Catches ALL RequestExceptions — mid-body connection drops surface as
    ChunkedEncodingError/IncompleteRead (observed live 2026-07-16 on
    multi-hundred-MB Socrata CSV pages), which is neither a ConnectionError
    nor a Timeout. With stream=False the whole body is read HERE, so a
    retry covers body truncation too."""
    last_exc: Exception | None = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = requests.get(url, params=params, headers=request_headers(),
                                timeout=REQUEST_TIMEOUT_S, stream=stream)
            resp.raise_for_status()
            return resp
        except requests.exceptions.RequestException as e:
            last_exc = e
            if attempt < MAX_RETRIES:
                if log:
                    log.warning(f"retry {attempt}/{MAX_RETRIES - 1}", extra=str(e))
                time.sleep(2 * attempt)
    raise last_exc


def load_country_config(country_slug: str) -> dict:
    cfg_path = PIPELINE_ROOT / "configs" / "countries" / f"{country_slug}.yaml"
    if not cfg_path.exists():
        raise FileNotFoundError(f"country config not found: {cfg_path}")
    with open(cfg_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def socrata_sources(config: dict, block: str = "datasf") -> list[dict]:
    """The socrata sources of one protocol block — a source names its block
    with `block:` (default `datasf`, so SF sources need no key)."""
    return [s for s in config.get("sources", [])
            if s.get("type") == "socrata" and s.get("block", "datasf") == block]


def sanitize_field_name(name: str) -> str:
    """Socrata fieldNames are already snake_case for these datasets; guard
    against exotic characters and leading digits anyway (BQ column rules)."""
    out = re.sub(r"[^A-Za-z0-9_]", "_", name)
    if re.match(r"^\d", out):
        out = "_" + out
    return out


def fetch_views_metadata(domain: str, dataset_id: str, log: Logger) -> dict:
    """`/api/views/<id>.json` — dataset name, rowsUpdatedAt, column list
    (fieldName = API name, name = display name used by the bulk CSV header)."""
    url = f"https://{domain}/api/views/{dataset_id}.json"
    resp = get_with_retry(url, log=log)
    return resp.json()


def visible_columns(meta: dict) -> list[dict]:
    """Data columns only — system/computed columns have id -1 or a ':'-
    prefixed fieldName and never appear in /resource output or bulk CSV."""
    return [
        c for c in meta.get("columns", [])
        if not str(c.get("fieldName", "")).startswith(":")
    ]


def fetch_row_count(domain: str, dataset_id: str, log: Logger) -> int:
    url = f"https://{domain}/resource/{dataset_id}.json"
    resp = get_with_retry(url, params={"$select": "count(*) as n"}, log=log)
    return int(resp.json()[0]["n"])


def get_bigquery_client() -> bigquery.Client:
    """Reuse the credential resolution pattern from sync_datagouv_dataset.py."""
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


def string_schema(field_names: list[str]) -> list[bigquery.SchemaField]:
    schema = [bigquery.SchemaField(n, "STRING") for n in field_names]
    schema.append(bigquery.SchemaField("_synced_at", "TIMESTAMP"))
    return schema


# ---------------------------------------------------------------------------
# paged-json mode
# ---------------------------------------------------------------------------

def sync_paged_json(
    client: bigquery.Client,
    domain: str,
    source: dict,
    field_names: list[str],
    raw_dataset: str,
    page_size: int,
    synced_at: str,
    log: Logger,
) -> int:
    dataset_id = source["dataset_id"]
    table_ref = f"{PROJECT_ID}.{raw_dataset}.{source['target_table']}"
    url = f"https://{domain}/resource/{dataset_id}.json"
    order_by = source.get("order_by", ":id")

    expected = fetch_row_count(domain, dataset_id, log)
    log.info("rows to pull", extra=f"{expected:,} ($limit={page_size:,}, $order={order_by})")

    # 1. Page through the API, buffering rows to one local NDJSON.gz file.
    tmp_dir = Path(tempfile.mkdtemp(prefix=f"socrata_{dataset_id}_"))
    ndjson_path = tmp_dir / f"{dataset_id}.ndjson.gz"
    total_rows = 0
    offset = 0
    with gzip.open(ndjson_path, "wt", encoding="utf-8", compresslevel=6) as out:
        while True:
            params = {"$limit": page_size, "$offset": offset, "$order": order_by}
            resp = get_with_retry(url, params=params, log=log)
            # parse_float/parse_int=str keeps the API's lexical representation —
            # raw stays byte-faithful (typing happens in stg).
            page = json.loads(resp.text, parse_float=str, parse_int=str)
            if not page:
                break
            for rec in page:
                row = {}
                for name in field_names:
                    v = rec.get(name)
                    if v is not None and not isinstance(v, str):
                        v = json.dumps(v, ensure_ascii=False)  # rare non-scalars
                    if v is not None:
                        row[name] = v
                row["_synced_at"] = synced_at
                out.write(json.dumps(row, ensure_ascii=False) + "\n")
            total_rows += len(page)
            log.info("page fetched", extra=f"offset {offset:,} → {total_rows:,}/{expected:,}")
            offset += page_size
            if len(page) < page_size:
                break

    if total_rows != expected:
        raise RuntimeError(
            f"{dataset_id}: fetched {total_rows:,} rows but count(*)={expected:,} "
            "(dataset may have refreshed mid-sync — re-run)"
        )
    size_mb = ndjson_path.stat().st_size / (1 << 20)
    log.info("buffered", extra=f"{ndjson_path} ({size_mb:,.0f} MiB gz)")

    # 2. One gzipped NDJSON load job (BQ auto-detects gzip on media uploads).
    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
        schema=string_schema(field_names),
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )
    with open(ndjson_path, "rb") as f:
        job = client.load_table_from_file(f, table_ref, job_config=job_config)
    job.result()
    ndjson_path.unlink(missing_ok=True)

    n_rows = int(client.get_table(table_ref).num_rows)
    if n_rows != expected:
        raise RuntimeError(f"{dataset_id}: table has {n_rows:,} rows, expected {expected:,}")
    log.success(f"loaded {n_rows:,} rows", extra=table_ref)
    return n_rows


# ---------------------------------------------------------------------------
# bulk-csv mode
# ---------------------------------------------------------------------------

def sync_bulk_csv(
    client: bigquery.Client,
    domain: str,
    source: dict,
    meta: dict,
    raw_dataset: str,
    synced_at: str,
    log: Logger,
    csv_page_size: int = CSV_PAGE_SIZE_DEFAULT,
) -> int:
    dataset_id = source["dataset_id"]
    target_table = source["target_table"]
    url = f"https://{domain}/resource/{dataset_id}.csv"
    order_by = source.get("order_by", ":id")
    page_rows = int(source.get("csv_page_size", csv_page_size))

    expected = fetch_row_count(domain, dataset_id, log)
    n_pages = -(-expected // page_rows)
    log.info("rows to pull", extra=f"{expected:,} ({n_pages} CSV page(s) of {page_rows:,})")

    # 1. Pull the CSV in pages (each fully read in memory inside the retry —
    #    a mid-stream drop retries only that page), buffering everything to
    #    ONE local csv.gz on disk. Only the FIRST page keeps its header row;
    #    the header contains no newline, so byte-splitting on the first \n
    #    is safe even with quoted newlines in the data.
    tmp_dir = Path(tempfile.mkdtemp(prefix=f"socrata_{dataset_id}_"))
    csv_path = tmp_dir / f"{dataset_id}.csv.gz"
    header_line: str | None = None
    written = 0
    with gzip.open(csv_path, "wb", compresslevel=6) as out:
        offset = 0
        page_no = 0
        while offset < expected:
            params = {"$limit": page_rows, "$offset": offset, "$order": order_by}
            resp = get_with_retry(url, params=params, log=log)
            body = resp.content
            nl = body.index(b"\n")
            if header_line is None:
                header_line = body[:nl].decode("utf-8-sig").rstrip("\r")
                out.write(body)
            else:
                page_header = body[:nl].decode("utf-8-sig").rstrip("\r")
                if page_header != header_line:
                    raise RuntimeError(
                        f"{dataset_id}: header drift at offset {offset:,} "
                        f"({page_header!r} != {header_line!r})"
                    )
                out.write(body[nl + 1:])
            if not body.endswith(b"\n"):
                # Socrata CSV pages end with a trailing newline (verified
                # live 2026-07-16); guard anyway so pages can never merge.
                out.write(b"\n")
            written += len(body)
            page_no += 1
            log.info("page fetched", extra=f"{page_no}/{n_pages} (offset {offset:,}, {written / (1 << 20):,.0f} MiB)")
            offset += page_rows

    # 2. Map the header back to API field names via metadata (the /resource
    #    CSV endpoint uses API field names; the bulk views export uses
    #    display names — accept either).
    header = next(csv.reader([header_line]))
    display_to_field = {}
    for c in visible_columns(meta):
        display_to_field[c["name"]] = c["fieldName"]
        display_to_field.setdefault(c["fieldName"], c["fieldName"])
    try:
        field_names = [sanitize_field_name(display_to_field[h]) for h in header]
    except KeyError as e:
        raise RuntimeError(
            f"{dataset_id}: CSV header column {e} not found in views metadata "
            "— header/metadata drift, refusing to guess"
        )

    # 3. One CSV load job into a temp table (all STRING, quoted newlines on),
    #    then CTAS to stamp _synced_at, then drop the temp table.
    load_table = f"{PROJECT_ID}.{raw_dataset}.{target_table}__load"
    final_table = f"{PROJECT_ID}.{raw_dataset}.{target_table}"
    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.CSV,
        schema=[bigquery.SchemaField(n, "STRING") for n in field_names],
        skip_leading_rows=1,
        allow_quoted_newlines=True,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )
    with open(csv_path, "rb") as f:
        job = client.load_table_from_file(f, load_table, job_config=job_config)
    job.result()
    log.info("staged", extra=load_table)

    client.query(
        f"CREATE OR REPLACE TABLE `{final_table}` AS "
        f"SELECT *, TIMESTAMP('{synced_at}') AS _synced_at FROM `{load_table}`"
    ).result()
    client.delete_table(load_table, not_found_ok=True)
    csv_path.unlink(missing_ok=True)

    n_rows = int(client.get_table(final_table).num_rows)
    if n_rows != expected:
        raise RuntimeError(
            f"{dataset_id}: loaded {n_rows:,} rows but count(*)={expected:,} "
            "(dataset may have refreshed mid-sync — re-run)"
        )
    log.success(f"loaded {n_rows:,} rows", extra=final_table)
    return n_rows


# ---------------------------------------------------------------------------
# catalog snapshot
# ---------------------------------------------------------------------------

def build_catalog_rows(
    protocol: dict, sources: list[dict], metas: dict[str, dict]
) -> list[dict]:
    """One row per (dataset, column): dataset-level provenance (name,
    description, rowsUpdatedAt, dataset page URL) + per-column metadata."""
    page_base = protocol.get("dataset_page_base", f"https://{protocol['domain']}/d")
    out: list[dict] = []
    for source in sources:
        meta = metas[source["id"]]
        dataset_id = source["dataset_id"]

        def epoch_iso(key: str) -> str | None:
            v = meta.get(key)
            return (
                datetime.fromtimestamp(int(v), tz=timezone.utc).isoformat()
                if v is not None else None
            )

        for col in visible_columns(meta):
            out.append({
                "source_id": source["id"],
                "dataset_id": dataset_id,
                "dataset_name": meta.get("name"),
                "dataset_description": meta.get("description"),
                "dataset_page_url": f"{page_base}/{dataset_id}",
                "domain": protocol["domain"],
                "portal_name": protocol.get("portal_name"),
                "attribution": meta.get("attribution"),
                "category": meta.get("category"),
                "rows_updated_at": epoch_iso("rowsUpdatedAt"),
                "created_at": epoch_iso("createdAt"),
                "publication_date": epoch_iso("publicationDate"),
                "column_field_name": col.get("fieldName"),
                "column_display_name": col.get("name"),
                "column_data_type": col.get("dataTypeName"),
                "column_description": col.get("description"),
                "column_position": str(col.get("position")),
            })
    return out


def load_catalog(
    client: bigquery.Client,
    rows: list[dict],
    raw_dataset: str,
    catalog_table: str,
    synced_at: str,
    log: Logger,
) -> None:
    if not rows:
        raise ValueError("no catalog rows to load")
    field_names = [k for k in rows[0].keys()]
    for r in rows:
        r["_synced_at"] = synced_at
    table_ref = f"{PROJECT_ID}.{raw_dataset}.{catalog_table}"
    job_config = bigquery.LoadJobConfig(
        schema=string_schema(field_names),
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )
    job = client.load_table_from_json(rows, table_ref, job_config=job_config)
    job.result()
    log.success(f"loaded {len(rows):,} catalog rows", extra=table_ref)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("country", help="Country slug (e.g. us)")
    parser.add_argument("--block", default="datasf",
                        help="Protocol block name in the country YAML (default: datasf)")
    parser.add_argument("--source", help="Only sync this specific source id")
    parser.add_argument("--skip-catalog", action="store_true", help="Skip the catalog metadata snapshot")
    parser.add_argument("--dry-run", action="store_true", help="Plan only, don't fetch or load")
    args = parser.parse_args()

    log = Logger("sync_socrata")
    log.header(f"Socrata/SODA → BigQuery sync — country={args.country}, block={args.block}")

    config = load_country_config(args.country)
    protocol = config.get(args.block)
    if not protocol or protocol.get("protocol") != "socrata":
        log.error(f"no socrata protocol block '{args.block}' in {args.country}.yaml")
        return 2
    domain = protocol["domain"]
    page_size = int(protocol.get("page_size", PAGE_SIZE_DEFAULT))
    csv_page_size = int(protocol.get("csv_page_size", CSV_PAGE_SIZE_DEFAULT))
    raw_dataset = config.get("bq_raw_dataset", RAW_DATASET_DEFAULT)

    sources = socrata_sources(config, args.block)
    if args.source:
        sources = [s for s in sources if s["id"] == args.source]
        if not sources:
            log.error(f"source '{args.source}' not found in {args.country}.yaml")
            return 2

    log.info("sources to sync", extra=f"{len(sources)} source(s) on {domain}")
    if args.dry_run:
        log.section("Dry run — would sync:")
        for s in sources:
            log.info("would load", extra=f"{s['dataset_id']} ({s['mode']}) → {raw_dataset}.{s['target_table']}")
        if not args.skip_catalog:
            log.info("would snapshot catalog", extra=f"/api/views/<id>.json → {raw_dataset}.{protocol.get('catalog_table')}")
        return 0

    log.section("BigQuery client")
    client = get_bigquery_client()
    log.success("connected", extra=PROJECT_ID)

    synced_at = datetime.now(timezone.utc).isoformat()
    metas: dict[str, dict] = {}
    failures = 0
    for source in sources:
        log.section(f"Source: {source['id']} ({source['dataset_id']}, {source['mode']})")
        log.info("description", extra=source.get("description", ""))
        try:
            meta = fetch_views_metadata(domain, source["dataset_id"], log)
            metas[source["id"]] = meta
            field_names = [sanitize_field_name(c["fieldName"]) for c in visible_columns(meta)]
            log.info("metadata", extra=f"{meta.get('name')} — {len(field_names)} columns, "
                                       f"rowsUpdatedAt={meta.get('rowsUpdatedAt')}")
            if source["mode"] == "paged-json":
                sync_paged_json(client, domain, source, field_names, raw_dataset,
                                page_size, synced_at, log)
            elif source["mode"] == "bulk-csv":
                sync_bulk_csv(client, domain, source, meta, raw_dataset, synced_at,
                              log, csv_page_size)
            else:
                raise ValueError(f"unknown mode '{source['mode']}' (paged-json | bulk-csv)")
        except Exception as e:
            log.error(f"sync failed: {source['id']}", extra=str(e))
            failures += 1

    if not args.skip_catalog:
        # Always snapshot ALL socrata sources of the block (the catalog table
        # is WRITE_TRUNCATE — a --source partial sync must not drop the other
        # datasets' provenance rows).
        log.section("Catalog metadata snapshot")
        try:
            all_sources = socrata_sources(config, args.block)
            for s in all_sources:
                if s["id"] not in metas:
                    metas[s["id"]] = fetch_views_metadata(domain, s["dataset_id"], log)
            catalog_rows = build_catalog_rows(protocol, all_sources, metas)
            load_catalog(client, catalog_rows, raw_dataset,
                         protocol["catalog_table"], synced_at, log)
        except Exception as e:
            log.error("catalog snapshot failed", extra=str(e))
            failures += 1

    log.section("Summary")
    if failures:
        log.error(f"{failures} failure(s)")
        return 1
    log.success("sync OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
