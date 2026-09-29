#!/usr/bin/env python3
"""
Generic CKAN → BigQuery sync (protocol adapter).

Reads a country YAML config (e.g. `pipeline/configs/countries/br.yaml`),
resolves each `ckan` source and loads a pinned CKAN *resource* (a CSV file)
into BigQuery `raw.{target_table}` (WRITE_TRUNCATE). The protocol block
(default `ckan`) carries the portal domain, the API base and the catalog
table; each source pins a `resource_id` (never a name — names churn) and a
`target_table`.

Why a file-download adapter and not the CKAN DataStore API: the Recife
portal (dados.recife.pe.gov.br) publishes these series as plain CSV
resources, not all of which are datastore-active, and the DataStore
`_full_text`/paging surface is unreliable for the multi-hundred-thousand-row
credor series. Downloading the pinned resource CSV is the one path that
always works. Protocol facts this adapter encodes (verified live 2026-07-22):

  - The `/resource/<id>/download` URL 302-redirects to a time-signed S3
    object on `ckan-storage-download.app.emprel.gov.br`; `requests` follows
    redirects by default.
  - CSVs are `;`-delimited with `"`-quoted fields. Text fields are heavily
    space-padded (CPF/CNPJ padded to ~200 chars). Padding is kept
    BYTE-FAITHFUL in raw — trimming happens once, in stg.
  - Encoding is UTF-8 for the current series (the published data dictionary
    claiming ISO-8859-1 is stale — verified against the bytes 2026-07-22);
    `encoding` is per-source overridable for older latin-1 resources.
  - Decimal separator varies BY dataset (credor/contratos use '.',
    licitações uses ',') — kept as-is in raw, normalized in stg
    (macros/br_recife_helpers.sql).

Raw tables get an all-STRING schema + `_synced_at` (TIMESTAMP), byte-faithful
to the CSV. Column names are sanitized to snake_case (accent-stripped) for
BigQuery; the original header order is preserved. Each run also snapshots the
CKAN `resource_show` + `package_show` metadata (title, resource url, license,
last_modified → as_of) into the protocol catalog table (`raw.br_recife_catalog`)
— the provenance source of truth for stg/marts/exports.

Usage:
    python sync_ckan_dataset.py br                         # all ckan sources + catalog
    python sync_ckan_dataset.py br --source credor_2024    # one source (+ catalog)
    python sync_ckan_dataset.py br --skip-catalog          # skip catalog snapshot
    python sync_ckan_dataset.py br --dry-run               # plan only
    python sync_ckan_dataset.py br --block ckan            # explicit protocol block
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
import unicodedata
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
REQUEST_TIMEOUT_S = 600
MAX_RETRIES = 4
# csv.field_size_limit default (128 KB) is too small for the space-padded
# 200-char credor fields concatenated across a giant quoted cell; raise it.
csv.field_size_limit(16 * 1024 * 1024)


def get_with_retry(url: str, params: dict | None = None, log: Logger | None = None,
                   stream: bool = False) -> requests.Response:
    """GET with linear-backoff retries. Mirrors sync_socrata.get_with_retry —
    catches ALL RequestExceptions (mid-body drops on the signed-S3 CSVs
    surface as ChunkedEncodingError, neither ConnectionError nor Timeout)."""
    import time
    last_exc: Exception | None = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = requests.get(url, params=params, timeout=REQUEST_TIMEOUT_S,
                                stream=stream, allow_redirects=True)
            resp.raise_for_status()
            return resp
        except requests.exceptions.RequestException as e:
            last_exc = e
            if attempt < MAX_RETRIES:
                if log:
                    log.warning(f"retry {attempt}/{MAX_RETRIES - 1}", extra=str(e))
                time.sleep(2 * attempt)
    raise last_exc



def download_resumable(url: str, path: Path, log: Logger, max_rounds: int = 30) -> None:
    """Stream `url` to `path`, resuming where a dropped connection left off.

    The portal's download URL 302-redirects to a TIME-SIGNED S3 object; the
    signature lapses after about ten minutes, and at the portal's ~70 KB/s an
    80 MB historical CSV (despesas orçamentárias 2002-2023) takes longer than
    that — the body is cut mid-stream (IncompleteRead). Each round asks the
    CKAN URL again (a fresh signature) with a Range header from the bytes
    already written. A server that ignores Range (200 instead of 206) restarts
    the file from zero."""
    import time
    total: int | None = None
    for rnd in range(1, max_rounds + 1):
        have = path.stat().st_size if path.exists() else 0
        if total is not None and have >= total:
            return
        headers = {"Range": f"bytes={have}-"} if have else {}
        try:
            with requests.get(url, headers=headers, timeout=REQUEST_TIMEOUT_S, stream=True, allow_redirects=True) as resp:
                if resp.status_code == 416:  # nothing left to send
                    return
                resp.raise_for_status()
                if resp.status_code == 206:
                    cr = resp.headers.get("Content-Range", "")
                    if "/" in cr and cr.rsplit("/", 1)[1].isdigit():
                        total = int(cr.rsplit("/", 1)[1])
                    mode = "ab"
                else:
                    cl = resp.headers.get("Content-Length")
                    total = int(cl) if cl and cl.isdigit() else None
                    mode = "wb"
                with open(path, mode) as f:
                    for chunk in resp.iter_content(chunk_size=1 << 20):
                        if chunk:
                            f.write(chunk)
            done = path.stat().st_size
            if total is None or done >= total:
                return
        except requests.exceptions.RequestException as e:
            done = path.stat().st_size if path.exists() else 0
            log.warning(f"download cut at {done / (1 << 20):,.1f} MiB — resuming ({rnd}/{max_rounds})", extra=str(e)[:120])
            time.sleep(2)
    raise RuntimeError(f"download did not complete after {max_rounds} rounds: {url}")

def load_country_config(country_slug: str) -> dict:
    cfg_path = PIPELINE_ROOT / "configs" / "countries" / f"{country_slug}.yaml"
    if not cfg_path.exists():
        raise FileNotFoundError(f"country config not found: {cfg_path}")
    with open(cfg_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def ckan_sources(config: dict) -> list[dict]:
    return [s for s in config.get("sources", []) if s.get("type") == "ckan"]


def sanitize_field_name(name: str) -> str:
    """Portuguese header → BQ-safe snake_case: NFD accent-strip, lowercase,
    non-alnum → '_', collapse repeats, trim, prefix leading digit."""
    nfkd = unicodedata.normalize("NFKD", name)
    ascii_str = nfkd.encode("ascii", "ignore").decode("ascii")
    out = re.sub(r"[^A-Za-z0-9]+", "_", ascii_str).strip("_").lower()
    if not out:
        out = "col"
    if re.match(r"^\d", out):
        out = "_" + out
    return out


def unique_field_names(header: list[str]) -> list[str]:
    seen: dict[str, int] = {}
    out: list[str] = []
    for h in header:
        base = sanitize_field_name(h)
        if base in seen:
            seen[base] += 1
            out.append(f"{base}_{seen[base]}")
        else:
            seen[base] = 0
            out.append(base)
    return out


def string_schema(field_names: list[str]) -> list[bigquery.SchemaField]:
    schema = [bigquery.SchemaField(n, "STRING") for n in field_names]
    schema.append(bigquery.SchemaField("_synced_at", "TIMESTAMP"))
    return schema


def get_bigquery_client() -> bigquery.Client:
    """Reuse the credential resolution pattern from sync_socrata.py."""
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


# ---------------------------------------------------------------------------
# CKAN metadata
# ---------------------------------------------------------------------------

def ckan_action(api_base: str, action: str, log: Logger, **params) -> dict:
    url = f"{api_base.rstrip('/')}/{action}"
    resp = get_with_retry(url, params=params, log=log)
    payload = resp.json()
    if not payload.get("success"):
        raise RuntimeError(f"CKAN {action} failed: {payload.get('error')}")
    return payload["result"]


def fetch_resource_meta(api_base: str, resource_id: str, log: Logger) -> dict:
    return ckan_action(api_base, "resource_show", log, id=resource_id)


def fetch_package_meta(api_base: str, package_id: str, log: Logger) -> dict:
    return ckan_action(api_base, "package_show", log, id=package_id)


# ---------------------------------------------------------------------------
# download + land
# ---------------------------------------------------------------------------

def sync_resource(
    client: bigquery.Client,
    source: dict,
    res_meta: dict,
    raw_dataset: str,
    synced_at: str,
    log: Logger,
) -> int:
    """Download the pinned CSV resource, parse it byte-faithfully, and land
    it as an all-STRING NDJSON load into raw.{target_table}."""
    target_table = source["target_table"]
    delimiter = source.get("csv_delimiter", ";")
    encoding = source.get("csv_encoding", "utf-8")
    download_url = source.get("download_url") or res_meta.get("url")
    if not download_url:
        raise RuntimeError(f"{source['id']}: no download url in resource metadata")

    table_ref = f"{PROJECT_ID}.{raw_dataset}.{target_table}"

    # 1. Stream the CSV to a temp file (follows the 302 → signed S3).
    tmp_dir = Path(tempfile.mkdtemp(prefix=f"ckan_{source['id']}_"))
    csv_path = tmp_dir / "resource.csv"
    log.info("downloading", extra=download_url[:100])
    download_resumable(download_url, csv_path, log)
    size_mb = csv_path.stat().st_size / (1 << 20)
    log.info("downloaded", extra=f"{size_mb:,.1f} MiB → {csv_path}")

    # 2. Parse (byte-faithful strings, padding preserved) → one NDJSON.gz.
    ndjson_path = tmp_dir / "rows.ndjson.gz"
    total_rows = 0
    field_names: list[str] = []
    with open(csv_path, "r", encoding=encoding, newline="") as fin, \
            gzip.open(ndjson_path, "wt", encoding="utf-8", compresslevel=6) as out:
        reader = csv.reader(fin, delimiter=delimiter, quotechar='"')
        header = next(reader)
        field_names = unique_field_names(header)
        n_cols = len(field_names)
        for raw_row in reader:
            if not raw_row or all(c == "" for c in raw_row):
                continue
            # Tolerate ragged rows (rare trailing-column drift): pad/truncate.
            if len(raw_row) < n_cols:
                raw_row = raw_row + [""] * (n_cols - len(raw_row))
            elif len(raw_row) > n_cols:
                raw_row = raw_row[:n_cols]
            row = {name: val for name, val in zip(field_names, raw_row) if val != ""}
            row["_synced_at"] = synced_at
            out.write(json.dumps(row, ensure_ascii=False) + "\n")
            total_rows += 1
    log.info("parsed", extra=f"{total_rows:,} rows, {n_cols} columns")

    # 3. One gzipped NDJSON load job (all STRING + _synced_at TIMESTAMP).
    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
        schema=string_schema(field_names),
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )
    with open(ndjson_path, "rb") as f:
        job = client.load_table_from_file(f, table_ref, job_config=job_config)
    job.result()
    ndjson_path.unlink(missing_ok=True)
    csv_path.unlink(missing_ok=True)

    n_rows = int(client.get_table(table_ref).num_rows)
    if n_rows != total_rows:
        raise RuntimeError(
            f"{source['id']}: table has {n_rows:,} rows, parsed {total_rows:,}"
        )
    log.success(f"loaded {n_rows:,} rows", extra=table_ref)
    return n_rows


# ---------------------------------------------------------------------------
# catalog snapshot
# ---------------------------------------------------------------------------

def build_catalog_rows(
    protocol: dict, sources: list[dict],
    res_metas: dict[str, dict], pkg_metas: dict[str, dict],
) -> list[dict]:
    """One row per source: resource-level provenance (title, url, license,
    last_modified → as_of) so every mart can carry source_url/as_of."""
    domain = protocol["domain"]
    page_base = protocol.get("dataset_page_base", f"https://{domain}/dataset")
    out: list[dict] = []
    for source in sources:
        rm = res_metas[source["id"]]
        pm = pkg_metas.get(rm.get("package_id"), {})
        out.append({
            "source_id": source["id"],
            "resource_id": rm.get("id"),
            "package_id": rm.get("package_id"),
            "dataset_title": pm.get("title"),
            "dataset_notes": (pm.get("notes") or "")[:1000] or None,
            "resource_name": rm.get("name"),
            "resource_url": rm.get("url"),
            "dataset_page_url": (
                f"{page_base}/{pm.get('name')}" if pm.get("name")
                else f"{page_base}/{rm.get('package_id')}"
            ),
            "resource_page_url": (
                f"{page_base}/{pm.get('name') or rm.get('package_id')}"
                f"/resource/{rm.get('id')}"
            ),
            "domain": domain,
            "portal_name": protocol.get("portal_name"),
            "license_title": pm.get("license_title"),
            "license_id": pm.get("license_id"),
            "attribution": pm.get("author") or (pm.get("organization") or {}).get("title"),
            "format": rm.get("format"),
            "size_bytes": str(rm.get("size")) if rm.get("size") is not None else None,
            "created": rm.get("created"),
            "last_modified": rm.get("last_modified") or rm.get("metadata_modified"),
            "rows_updated_at": rm.get("last_modified") or rm.get("metadata_modified"),
        })
    return out


def load_catalog(
    client: bigquery.Client, rows: list[dict], raw_dataset: str,
    catalog_table: str, synced_at: str, log: Logger,
) -> None:
    if not rows:
        raise ValueError("no catalog rows to load")
    field_names = list(rows[0].keys())
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
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("country", help="Country slug (e.g. br)")
    parser.add_argument("--block", default="ckan",
                        help="Protocol block name in the country YAML (default: ckan)")
    parser.add_argument("--source", help="Only sync this specific source id")
    parser.add_argument("--skip-catalog", action="store_true",
                        help="Skip the catalog metadata snapshot")
    parser.add_argument("--dry-run", action="store_true",
                        help="Plan only, don't fetch or load")
    args = parser.parse_args()

    log = Logger("sync_ckan")
    log.header(f"CKAN → BigQuery sync — country={args.country}, block={args.block}")

    config = load_country_config(args.country)
    protocol = config.get(args.block)
    if not protocol or protocol.get("protocol") != "ckan":
        log.error(f"no ckan protocol block '{args.block}' in {args.country}.yaml")
        return 2
    api_base = protocol["api_base"]
    raw_dataset = config.get("bq_raw_dataset", RAW_DATASET_DEFAULT)

    sources = ckan_sources(config)
    if args.source:
        sources = [s for s in sources if s["id"] == args.source]
        if not sources:
            log.error(f"source '{args.source}' not found in {args.country}.yaml")
            return 2

    log.info("sources to sync", extra=f"{len(sources)} source(s) on {protocol['domain']}")
    if args.dry_run:
        log.section("Dry run — would sync:")
        for s in sources:
            log.info("would load",
                     extra=f"resource {s['resource_id']} → {raw_dataset}.{s['target_table']}")
        if not args.skip_catalog:
            log.info("would snapshot catalog",
                     extra=f"resource_show/package_show → {raw_dataset}.{protocol.get('catalog_table')}")
        return 0

    log.section("BigQuery client")
    client = get_bigquery_client()
    log.success("connected", extra=PROJECT_ID)

    synced_at = datetime.now(timezone.utc).isoformat()
    res_metas: dict[str, dict] = {}
    pkg_metas: dict[str, dict] = {}
    failures = 0

    def load_meta(source: dict) -> dict:
        rm = fetch_resource_meta(api_base, source["resource_id"], log)
        res_metas[source["id"]] = rm
        pkg_id = rm.get("package_id")
        if pkg_id and pkg_id not in pkg_metas:
            try:
                pkg_metas[pkg_id] = fetch_package_meta(api_base, pkg_id, log)
            except Exception as e:  # package metadata is best-effort
                log.warning("package_show failed", extra=str(e))
                pkg_metas[pkg_id] = {}
        return rm

    for source in sources:
        log.section(f"Source: {source['id']} (resource {source['resource_id']})")
        log.info("description", extra=source.get("description", ""))
        try:
            rm = load_meta(source)
            log.info("metadata", extra=f"{rm.get('name')} — format={rm.get('format')}, "
                                       f"last_modified={rm.get('last_modified')}")
            sync_resource(client, source, rm, raw_dataset, synced_at, log)
        except Exception as e:
            log.error(f"sync failed: {source['id']}", extra=str(e))
            failures += 1

    if not args.skip_catalog:
        # Snapshot ALL ckan sources (catalog is WRITE_TRUNCATE — a --source
        # partial sync must not drop the other datasets' provenance rows).
        log.section("Catalog metadata snapshot")
        try:
            all_sources = ckan_sources(config)
            for s in all_sources:
                if s["id"] not in res_metas:
                    load_meta(s)
            catalog_rows = build_catalog_rows(protocol, all_sources, res_metas, pkg_metas)
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
