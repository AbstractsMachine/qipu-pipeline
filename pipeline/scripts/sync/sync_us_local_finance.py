#!/usr/bin/env python3
"""
US local government finance → BigQuery raw.us_* sync.

Reads the local-finance sources from `pipeline/configs/countries/us.yaml`
(types below) and loads each one into `raw.{target_table}` AS ALL STRINGS
(typing happens in stg), plus `_source`, `_source_url`, `_synced_at`.

Protocol adapters (one per `type:`):
  census_iuf        Census of Governments / Annual Survey of Local Government
                    Finances, Individual Unit File (fixed-width, 32 chars, amounts
                    in thousands). Every US local government in census years
                    (2017, 2022), a ~25k-unit sample in between. Two tables:
                    finance records and the unit directory (PID).
  iowa_datahub      Iowa Data Hub dataset export (zipped CSV), direct URL
                    /api/dataset-download?path=datasets/<id>/rows.csv.
  indiana_gateway   Indiana Gateway download form (ASP.NET postback, no auth):
                    one pipe-delimited file per (unit type, year).
  ma_dls_logi       Massachusetts DLS Gateway (Logi report server) NativeExcel
                    export. Logi binds a parameter only when its GUID-suffixed
                    twin is sent too — without it the report returns an empty
                    shell (verified 2026-09-18).
  fl_edr_xlsx       Florida EDR per-municipality workbooks, one sheet per fiscal
                    year, rows = Uniform Accounting System account codes,
                    columns = fund types (matched by header label, not position).

Volume guard: an existing table is only replaced when the new load has at
least MIN_KEEP_RATIO of its rows (--force to override, after checking why).

Why these four states: see memory project_us_municipal_finance_sources —
IA and IN publish budget AND actuals in one nomenclature, MA gives actuals by
function 2002+ and voted totals, FL gives actuals by UAS function code.

Usage:
    python pipeline/scripts/sync/sync_us_local_finance.py us
    python pipeline/scripts/sync/sync_us_local_finance.py us --only in_budget_line_items
    python pipeline/scripts/sync/sync_us_local_finance.py us --dry-run   # fetch + parse, no load
"""

from __future__ import annotations

import argparse
import csv
import gzip
import html
import io
import json
import os
import re
import socket
import sys
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import requests
import yaml

PIPELINE_ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(PIPELINE_ROOT / "scripts"))

from utils.logger import Logger  # noqa: E402

PROJECT_ID = "open-data-france-484717"
MIN_KEEP_RATIO = 0.9
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")
THIS_YEAR = datetime.now(timezone.utc).year


def session() -> requests.Session:
    s = requests.Session()
    s.headers["User-Agent"] = UA
    return s


def get(s: requests.Session, url: str, *, timeout: int = 180, attempts: int = 4, **kw) -> requests.Response:
    """GET with backoff: state servers drop connections and DNS answers on long
    runs (seen 2026-09-22 on edr.state.fl.us and gateway.ifionline.org)."""
    import time
    for attempt in range(1, attempts + 1):
        try:
            r = s.get(url, timeout=timeout, **kw)
            r.raise_for_status()
            return r
        except requests.HTTPError as e:
            status = e.response.status_code if e.response is not None else 0
            if 400 <= status < 500 and status != 429:
                raise  # the file is not there: retrying cannot help (e.g. an unpublished Census year)
            if attempt == attempts:
                raise
            time.sleep(8 * attempt)
        except requests.RequestException:
            if attempt == attempts:
                raise
            time.sleep(8 * attempt)


def force_ipv4() -> None:
    """www2.census.gov hangs on IPv6 from some networks (see sync_census_popest.py)."""
    orig = socket.getaddrinfo

    def ipv4_only(host, port, family=0, type=0, proto=0, flags=0):
        return orig(host, port, socket.AF_INET, type, proto, flags)

    socket.getaddrinfo = ipv4_only


def year_range(spec) -> list[int]:
    """`years:` is either a list or {from: 2002, to: current|next|<int>}."""
    if isinstance(spec, list):
        return [int(y) for y in spec]
    end = spec.get("to", "current")
    end = THIS_YEAR + 1 if end == "next" else THIS_YEAR if end == "current" else int(end)
    return list(range(int(spec["from"]), end + 1))


# --------------------------------------------------------------------------- adapters
# Each adapter returns (rows, columns, source_url). rows are dicts of str|None.

def fetch_census_iuf(src: dict, log: Logger):
    """6.5M finance rows for 2017-2024: the zips are kept (~50 MB), rows stream."""
    force_ipv4()
    s = session()
    zips = []
    for year in year_range(src["years"]):
        for suffix in ("", "s"):  # 2017-2022: _File.zip ; 2023+: _Files.zip
            try:
                r = get(s, src["url_pattern"].format(year=year, s=suffix), timeout=300)
            except requests.RequestException:
                continue
            if r.content[:2] == b"PK":
                zips.append((year, zipfile.ZipFile(io.BytesIO(r.content))))
                log.info(f"census IUF {year}", extra=f"{len(r.content) / 1e6:.1f} MB")
                break
        else:
            log.warning(f"census IUF {year}: not published")

    def member(z, pattern):
        return next(n for n in z.namelist() if re.search(pattern, n))

    def finance():
        for year, z in zips:
            for line in z.read(member(z, r"FinEstDAT")).decode("latin-1").splitlines():
                if len(line) >= 31:
                    yield {"unit_id": line[0:12], "item_code": line[12:15],
                           "amount_thousands": line[15:27].strip(), "data_year": line[27:31],
                           "imputation_flag": line[31:32] or None, "file_year": str(year)}

    def units():
        for year, z in zips:
            for line in z.read(member(z, r"Fin_PID_\d{4}\.txt$")).decode("latin-1").splitlines():
                if len(line) >= 127:
                    yield {"unit_id": line[0:12], "name": line[12:76].strip(),
                           "county_name": line[76:111].strip(), "fips_place": line[111:116].strip() or None,
                           "population": line[116:125].strip() or None,
                           "population_year": line[125:127].strip() or None,
                           "enrollment": line[127:134].strip() or None,
                           "special_district_function": line[136:138].strip() or None,
                           "school_level": line[138:140].strip() or None,
                           "fiscal_year_ending": line[140:144].strip() or None,
                           "survey_year": line[144:146].strip() or None, "file_year": str(year)}

    fin_cols = ["unit_id", "item_code", "amount_thousands", "data_year", "imputation_flag", "file_year"]
    unit_cols = ["unit_id", "name", "county_name", "fips_place", "population", "population_year",
                 "enrollment", "special_district_function", "school_level", "fiscal_year_ending",
                 "survey_year", "file_year"]
    url = src["url_pattern"]
    return {src["target_table"]: (finance(), fin_cols, url), src["units_table"]: (units(), unit_cols, url)}


def fetch_iowa_datahub(src: dict, log: Logger):
    """The zip is streamed to disk and its rows streamed out: dataset 926
    (certified budget line items) is 637 MB in FIVE csv parts — holding it in
    memory would exhaust it, and reading the first part only (as this adapter
    did until 2026-09-22) would load a fifth of it without a word. 925 and
    928 are one part each, so nothing loaded before was cut."""
    url = f"https://data.iowa.gov/api/dataset-download?path=datasets%2F{src['dataset_id']}%2Frows.csv"
    tmp = tempfile.NamedTemporaryFile(suffix=".zip", delete=False)
    with session().get(url, timeout=600, stream=True) as r:
        r.raise_for_status()
        for chunk in r.iter_content(1 << 20):
            tmp.write(chunk)
    tmp.close()
    with open(tmp.name, "rb") as f:
        if f.read(2) != b"PK":
            raise RuntimeError(f"Iowa dataset {src['dataset_id']}: expected a zip")
    z = zipfile.ZipFile(tmp.name)
    parts = sorted(n for n in z.namelist() if n.endswith(".csv"))
    log.info(f"Iowa dataset {src['dataset_id']}", extra=f"{os.path.getsize(tmp.name) / 1e6:.0f} MB, {len(parts)} part(s)")
    with z.open(parts[0]) as f:
        cols = csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig")).fieldnames

    def rows():
        try:
            for name in parts:
                with z.open(name) as f:
                    reader = csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig"))
                    if reader.fieldnames != cols:
                        raise RuntimeError(f"Iowa dataset {src['dataset_id']}: {name} has other columns than {parts[0]}")
                    for row in reader:
                        yield {k: (v if v != "" else None) for k, v in row.items()}
        finally:
            z.close()
            os.unlink(tmp.name)

    return {src["target_table"]: (rows(), list(cols), url)}


IN_URL = "https://gateway.ifionline.org/public/download.aspx"
IN_P = "ctl00$ContentPlaceHolder1$"


def _in_hidden(page: str) -> dict:
    out = {}
    for m in re.finditer(r'<input[^>]*type="hidden"[^>]*>', page):
        n = re.search(r'name="([^"]+)"', m.group(0))
        v = re.search(r'value="([^"]*)"', m.group(0))
        if n:
            out[n.group(1)] = html.unescape(v.group(1) if v else "")
    return out


def _in_options(page: str, name: str) -> dict[str, str]:
    body = re.search(r'<select[^>]*name="' + re.escape(IN_P + name) + r'"[^>]*>(.*?)</select>', page, re.S)
    if not body:
        raise RuntimeError(f"Indiana Gateway: select {name} not found (form changed?)")
    return {html.unescape(l).strip(): v for v, l in re.findall(r'<option[^>]*value="([^"]*)"[^>]*>([^<]+)</option>', body.group(1))}


def _in_download(s: requests.Session, kind: str, sub: str, unit_type: str, year: str) -> bytes | None:
    """One file = GET form, postback on the dataset list (it repopulates the
    sub-datasets), then POST the download. Returns None when the year is not
    offered or the server answers without a file."""
    page = get(s, IN_URL, timeout=120).text
    kinds = _in_options(page, "RadComboBox1")
    form = _in_hidden(page)
    form.update({IN_P + "RadComboBox1": kinds[kind], "__EVENTTARGET": IN_P + "RadComboBox1", "__EVENTARGUMENT": ""})
    page = s.post(IN_URL, data=form, headers={"Referer": IN_URL}, timeout=180).text
    subs, units, years = (_in_options(page, n) for n in ("RadComboBox2", "DropDownListUnitType", "DropDownListYear"))
    if year not in years:
        return None
    form = _in_hidden(page)
    form.update({IN_P + "RadComboBox1": kinds[kind], IN_P + "RadComboBox2": subs[sub],
                 IN_P + "DropDownListUnitType": units[unit_type], IN_P + "DropDownListYear": years[year],
                 IN_P + "button_download1": "Download", "__EVENTTARGET": "", "__EVENTARGUMENT": ""})
    r = s.post(IN_URL, data=form, headers={"Referer": IN_URL}, timeout=300)  # a good year is ~1 min; a stall is not
    if "attachment" not in r.headers.get("content-disposition", ""):
        return None
    return r.content


def fetch_indiana_gateway(src: dict, log: Logger):
    """Streams year by year: one year is 7-18 MB and ~85k rows, eight years
    held together exhausted memory on 2026-09-22. The first file is fetched
    eagerly to learn the columns; the rest are fetched as the load consumes."""
    import time

    def download(unit_type: str, year: str) -> bytes | None:
        s = session()
        for attempt in range(1, 5):
            try:
                return _in_download(s, src["kind"], src["subkind"], unit_type, year)
            except (requests.RequestException, ValueError) as e:  # dropped connections on big files
                log.warning(f"Indiana {unit_type} {year}: attempt {attempt} failed", extra=str(e)[:120])
                time.sleep(10 * attempt)
                s = session()
        raise RuntimeError(f"Indiana {src['subkind']} {unit_type} {year}: 4 attempts failed")

    def parse(content: bytes):
        # UTF-8 first: decoding as latin-1 turned an en dash into "â\x80\x93" (seen 2026-09-22,
        # "LIT – Economic Development"); latin-1 stays the fallback for older files.
        try:
            text = content.decode("utf-8-sig")
        except UnicodeDecodeError:
            text = content.decode("latin-1")
        reader = csv.reader(io.StringIO(text), delimiter="|")
        return [h.strip() for h in next(reader) if h.strip()], reader  # every line ends with '|'

    jobs = [(u, str(y)) for u in src["unit_types"] for y in year_range(src["years"])]
    first = None
    while jobs and first is None:
        u, y = jobs.pop(0)
        content = download(u, y)
        if content is None or b"Data Not Available" in content[:400]:
            log.info(f"Indiana {u} {y}", extra="not offered")
        else:
            first = (u, y, content)
    if first is None:
        raise RuntimeError(f"Indiana {src['subkind']}: nothing downloaded")
    header, _ = parse(first[2])
    cols = header + ["unit_type_label"]

    def rows():
        pending = [first] + [(u, y, None) for u, y in jobs]
        for u, y, content in pending:
            content = content if content is not None else download(u, y)
            if content is None or b"Data Not Available" in content[:400]:
                # an unfiled year comes back as a one-line file, not as an error (2026 actuals, seen 2026-09-22)
                log.info(f"Indiana {u} {y}", extra="not offered")
                continue
            h, reader = parse(content)
            if h != header:
                raise RuntimeError(f"Indiana {src['subkind']} {y}: columns changed — {set(h) ^ set(header)}")
            n = 0
            for rec in reader:
                if any(rec):
                    row = {c: (rec[i].strip() if i < len(rec) and rec[i].strip() != "" else None) for i, c in enumerate(h)}
                    row["unit_type_label"] = u
                    n += 1
                    yield row
            log.info(f"Indiana {u} {y}", extra=f"{n:,} rows")

    return {src["target_table"]: (rows(), cols, IN_URL)}


MA_URL = "https://dlsgateway.dor.state.ma.us/reports/rdPage.aspx"


def _ma_export(s: requests.Session, report: str, table_id: str, params: dict, guid: str | None) -> list[list]:
    import pandas as pd
    q = {"rdReport": report, "rdReportFormat": "NativeExcel", "rdExportTableID": table_id, "rdExportFilename": "x"}
    for k, v in params.items():
        q[k] = v
        if guid:
            q[f"{k}_{guid}"] = v
    r = get(s, MA_URL, params=q, timeout=300)
    df = pd.read_excel(io.BytesIO(r.content), header=None, dtype=str)
    return df.where(df.notna(), None).values.tolist()


def fetch_ma_dls_logi(src: dict, log: Logger):
    s = session()
    rows, header = [], None
    years = year_range(src["years"]) if src.get("years") else [None]
    for year in years:
        params = dict(src.get("params", {}))
        if year is not None:
            params[src["year_param"]] = str(year)
        grid = _ma_export(s, src["report"], src["table_id"], params, src.get("param_guid"))
        if not grid:
            log.warning(f"MA {src['report']} {year}: empty export")
            continue
        h = [str(c).strip() if c is not None else "" for c in grid[0]]
        if header is None:
            header = h
        elif h != header:
            raise RuntimeError(f"MA {src['report']} {year}: header changed {h} vs {header}")
        n = 0
        for rec in grid[1:]:
            if rec[0] is None:
                continue
            rows.append({header[i]: (str(v).strip() if v is not None else None) for i, v in enumerate(rec) if header[i]})
            n += 1
        log.info(f"MA {src['report']} {year or ''}", extra=f"{n} rows")
    if header is None:
        raise RuntimeError(f"MA {src['report']}: nothing exported")
    cols = [c for c in header if c]
    return {src["target_table"]: (rows, cols, MA_URL + "?rdReport=" + src["report"])}


def _slug(label: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", label.lower()).strip("_")


FL_FUNDS = ["general", "special_revenue", "debt_service", "capital_projects", "permanent", "enterprise",
            "internal_service", "custodial", "agency", "pension", "trust", "private_purpose", "component_units",
            "total_account", "per_capita_account"]
FL_SYNONYMS = {"account_total": "total_account",       # 2020-2021 sheets say "Account Total"
               "privater_purpose": "private_purpose"}  # typo in belleairrevenues.xlsx 2023


def fetch_fl_edr_xlsx(src: dict, log: Logger):
    """Fund columns vary by year (e.g. no Custodial column before GASB 84), so
    each sheet is read by its own header labels and the table carries the
    union. A label outside FL_FUNDS is kept but announced."""
    import pandas as pd
    s = session()
    idx = get(s, src["index_url"], timeout=120).text
    files = sorted(set(re.findall(r'href="(munifiscal/[a-z0-9]+' + src["file_suffix"] + r'\.xlsx)"', idx)))
    if len(files) < 300:
        raise RuntimeError(f"Florida EDR: only {len(files)} {src['file_suffix']} files listed — index changed?")
    base = src["index_url"].rsplit("/", 1)[0] + "/"
    rows, extra = [], []
    for i, f in enumerate(files):
        muni = f.split("/")[-1][: -len(src["file_suffix"] + ".xlsx")]
        r = get(s, base + f, timeout=180)
        book = pd.ExcelFile(io.BytesIO(r.content))
        for sheet in book.sheet_names:
            if not re.fullmatch(r"\d{4}", sheet):
                continue
            g = pd.read_excel(book, sheet_name=sheet, header=None, dtype=str)
            g = g.where(g.notna(), None).values.tolist()
            title = (g[0][0] or "").strip()
            hdr_i = next((k for k, rec in enumerate(g[:8]) if len(rec) > 3 and rec[3] and rec[3].strip() == "General"), None)
            if hdr_i is None:
                raise RuntimeError(f"Florida {f} {sheet}: fund header row not found")
            labels = [(_slug(c) if c else None) for c in g[hdr_i]]
            if labels[-1] is None:
                labels[-1] = "per_capita_account"
            labels = [FL_SYNONYMS.get(l, l) if l else None for l in labels]
            for l in labels[3:]:
                if l and l not in FL_FUNDS and l not in extra:
                    extra.append(l)
                    log.warning(f"Florida: new fund column {l!r}", extra=f"{f} {sheet}")
            group = None
            for rec in g[hdr_i + 1:]:
                if rec[0] and not rec[1] and rec[0].startswith("Compiled from"):
                    break
                if rec[0] and not rec[1]:
                    group, level, code, name = rec[0].strip(), "group", None, rec[0].strip()
                elif rec[1]:
                    level, code, name = "account", rec[1].split(".")[0].strip(), (rec[2] or "").strip()
                else:
                    continue
                row = {"municipality_file": muni, "title": title, "fiscal_year": sheet, "level": level,
                       "group_name": group, "account_code": code, "account_name": name}
                for j, lab in enumerate(labels):
                    if j >= 3 and lab:
                        row[lab] = rec[j] if j < len(rec) else None
                rows.append(row)
        if (i + 1) % 100 == 0:
            log.info(f"Florida {src['file_suffix']}", extra=f"{i + 1}/{len(files)} files, {len(rows):,} rows")
    cols = ["municipality_file", "title", "fiscal_year", "level", "group_name", "account_code", "account_name"] + FL_FUNDS + extra
    return {src["target_table"]: (rows, cols, src["index_url"])}


def fetch_xlsx_by_year(src: dict, log: Logger):
    """One spreadsheet per year at a known URL (Indiana DLGF certified rates,
    Florida DOR millage): `files: {year: url}`. Every sheet is read when
    `all_sheets` (Florida files one sheet per county, named after it, kept as
    `sheet`); the header sits on `header_row`. Columns are the union over the
    years — a file that adds or renames a column does not drop the others."""
    import pandas as pd
    s = session()
    rows, cols = [], []
    for year, url in sorted(src["files"].items()):
        r = get(s, url, timeout=300)
        book = pd.ExcelFile(io.BytesIO(r.content))
        sheets = ([sh for sh in book.sheet_names if sh not in src.get("skip_sheets", [])]
                  if src.get("all_sheets")
                  else [src["sheet_name"]] if src.get("sheet_name")
                  else [book.sheet_names[src.get("sheet", 0)]])
        n = 0
        for sh in sheets:
            df = pd.read_excel(book, sh, header=src.get("header_row", 0), dtype=str)
            df.columns = [str(c).strip() for c in df.columns]
            df = df.loc[:, [c for c in df.columns if c and not c.startswith("Unnamed")]]
            for c in df.columns:
                if c not in cols:
                    cols.append(c)
            for rec in df.where(df.notna(), None).to_dict("records"):
                if not any(v for v in rec.values()):
                    continue
                rec = {k: (str(v).strip() if v is not None else None) for k, v in rec.items()}
                rec["file_year"] = str(year)
                if src.get("all_sheets"):
                    rec["sheet"] = sh
                rows.append(rec)
                n += 1
        log.info(f"{src['id']} {year}", extra=f"{n} rows, {len(sheets)} sheet(s)")
    cols = cols + ["file_year"] + (["sheet"] if src.get("all_sheets") else [])
    return {src["target_table"]: (rows, cols, next(iter(src["files"].values())))}


def fetch_iowa_drive_rates(src: dict, log: Logger):
    """Iowa DOM's City Property Tax Rate Files: one workbook per fiscal year in
    a public Google Drive folder (FY2000 → the year just certified), a report
    layout whose header runs over several rows and whose columns moved over
    the years. A city row is found by its code (`01G001`, the city_code the
    budget datasets use) with the name in the cell before it. Kept per row:
    every cell (JSON) and the composite header of each column (JSON), for
    audit; read from them, by their header, the TOTAL rate and the DEBT
    SERVICE levy ($ per $1,000 of taxable value)."""
    import pandas as pd
    s = session()
    page = get(s, f"https://drive.google.com/embeddedfolderview?id={src['folder_id']}", timeout=120).text
    files = re.findall(r'<a href="https://drive.google.com/file/d/([^/]+)/view[^"]*"[^>]*>.*?<div class="flip-entry-title">([^<]+)</div>', page, re.S)
    code_re = re.compile(r"^\d\dG\d{3}$")
    rows = []
    for fid, name in sorted(files, key=lambda x: x[1]):
        m = re.search(r"FY\s*(\d{4})", html.unescape(name))
        if not m:
            continue
        fy = m.group(1)
        r = get(s, f"https://drive.google.com/uc?export=download&id={fid}", timeout=300)
        df = pd.read_excel(io.BytesIO(r.content), sheet_name=0, header=None, dtype=str)
        grid = df.where(df.notna(), None).values.tolist()
        first = next((i for i, rec in enumerate(grid) if any(v and code_re.match(str(v).strip()) for v in rec)), None)
        if first is None:
            log.warning(f"Iowa rates FY{fy}: no city row found")
            continue
        heads = [" ".join(str(grid[i][c]).strip() for i in range(first) if grid[i][c]) .upper() for c in range(len(grid[0]))]
        n = 0
        for rec in grid[first:]:
            ci = next((c for c, v in enumerate(rec) if v and code_re.match(str(v).strip())), None)
            if ci is None:
                continue
            nums = {}
            for c, v in enumerate(rec):
                try:
                    nums[c] = float(str(v).replace(",", ""))
                except (TypeError, ValueError):
                    pass
            total_cols = [c for c in nums if "TOTAL" in heads[c]]
            debt_cols = [c for c in nums if "DEBT" in heads[c]]
            rows.append({
                "fiscal_year": fy,
                "city_code": str(rec[ci]).strip(),
                "city_name": str(rec[ci - 1]).strip() if ci > 0 and rec[ci - 1] else None,
                "total_rate": str(nums[total_cols[-1]]) if total_cols else (str(nums[max(nums)]) if nums else None),
                "total_rate_basis": "total_column" if total_cols else "last_number",
                "debt_service_rate": str(nums[debt_cols[0]]) if debt_cols else None,
                "cells_json": json.dumps([None if v is None else str(v) for v in rec]),
                "headers_json": json.dumps(heads),
                "file_name": html.unescape(name),
            })
            n += 1
        log.info(f"Iowa rates FY{fy}", extra=f"{n} cities")
    cols = ["fiscal_year", "city_code", "city_name", "total_rate", "total_rate_basis", "debt_service_rate",
            "cells_json", "headers_json", "file_name"]
    return {src["target_table"]: (rows, cols, f"https://drive.google.com/drive/folders/{src['folder_id']}")}


def fetch_iowa_debt_html(src: dict, log: Logger):
    """Iowa Treasurer's outstanding obligations report (debtreportingiowa.gov):
    one HTML page per fiscal year, every public body with its total
    outstanding debt at June 30, population and debt per capita, under
    section rows (a row repeating one label in every cell: "City", "County",
    "Board of Regents"…), kept as `section`."""
    import pandas as pd
    s = session()
    rows = []
    for fy in year_range(src["years"]):
        url = src["url_pattern"].format(fy=fy)
        try:
            r = get(s, url, timeout=180)
        except requests.RequestException as e:
            log.warning(f"Iowa debt FY{fy}: {e}")
            continue
        tables = pd.read_html(io.StringIO(r.text))
        if not tables:
            continue
        t = max(tables, key=lambda x: x.shape[0]).astype(str)
        section, n = None, 0
        for rec in t.values.tolist()[1:]:
            cells = [c.strip() for c in rec]
            if len(set(cells)) == 1:
                section = cells[0]
                continue
            rows.append({"fiscal_year": str(fy), "section": section, "name": cells[0],
                         "total_outstanding": cells[1], "population": cells[2], "per_capita": cells[3]})
            n += 1
        log.info(f"Iowa debt FY{fy}", extra=f"{n} bodies")
    cols = ["fiscal_year", "section", "name", "total_outstanding", "population", "per_capita"]
    return {src["target_table"]: (rows, cols, src["url_pattern"].format(fy="<fy>"))}


ADAPTERS = {
    "census_iuf": fetch_census_iuf,
    "iowa_datahub": fetch_iowa_datahub,
    "indiana_gateway": fetch_indiana_gateway,
    "ma_dls_logi": fetch_ma_dls_logi,
    "fl_edr_xlsx": fetch_fl_edr_xlsx,
    "xlsx_by_year": fetch_xlsx_by_year,
    "iowa_drive_rates": fetch_iowa_drive_rates,
    "iowa_debt_html": fetch_iowa_debt_html,
}


# --------------------------------------------------------------------------- load

def get_bigquery_client():
    from google.cloud import bigquery
    creds = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not creds:
        for p in [Path.home() / ".config" / "gcloud" / "application_default_credentials.json",
                  PIPELINE_ROOT.parent / "credentials.json", PIPELINE_ROOT / "credentials.json"]:
            if p.exists():
                os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = str(p)
                break
    return bigquery.Client(project=PROJECT_ID)


def bq_name(col: str) -> str:
    """BigQuery column names: letters, digits, underscores ("DOR Code" → dor_code)."""
    n = re.sub(r"[^a-z0-9]+", "_", col.strip().lower()).strip("_")
    return n if n and not n[0].isdigit() else f"c_{n}"


def load(client, dataset: str, table: str, rows, cols: list[str], source: str, url: str,
         force: bool, log: Logger) -> int:
    """Streams rows to a gzipped NDJSON file, then applies the volume guard, then loads."""
    from google.cloud import bigquery
    from google.api_core.exceptions import NotFound
    ref = f"{PROJECT_ID}.{dataset}.{table}"
    bq_cols = [bq_name(c) for c in cols]
    if len(set(bq_cols)) != len(bq_cols):
        raise RuntimeError(f"{table}: column names collide once normalised — {bq_cols}")
    synced_at = datetime.now(timezone.utc).isoformat()
    tmp = tempfile.NamedTemporaryFile(suffix=".json.gz", delete=False).name
    n = 0
    try:
        with gzip.open(tmp, "wt", encoding="utf-8") as gz:
            for r in rows:
                rec = {b: r.get(c) for c, b in zip(cols, bq_cols)}
                rec.update(_source=source, _source_url=url, _synced_at=synced_at)
                gz.write(json.dumps(rec, ensure_ascii=False) + "\n")
                n += 1
        if n == 0:
            raise RuntimeError(f"{table}: 0 rows parsed")
        try:
            existing = client.get_table(ref).num_rows
        except NotFound:
            existing = 0
        if existing and n < MIN_KEEP_RATIO * existing and not force:
            raise RuntimeError(f"volume guard: {table} would go from {existing:,} to {n:,} rows — "
                               f"refused (check the source, then --force)")
        schema = [bigquery.SchemaField(c, "STRING") for c in bq_cols] + [
            bigquery.SchemaField("_source", "STRING"), bigquery.SchemaField("_source_url", "STRING"),
            bigquery.SchemaField("_synced_at", "TIMESTAMP")]
        cfg = bigquery.LoadJobConfig(schema=schema, source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
                                     write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE)
        with open(tmp, "rb") as fh:
            client.load_table_from_file(fh, ref, job_config=cfg).result()
    finally:
        os.unlink(tmp)
    log.success(f"loaded {client.get_table(ref).num_rows:,} rows (parsed {n:,})", extra=ref)
    return n


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("country")
    ap.add_argument("--only", help="comma-separated source ids")
    ap.add_argument("--dry-run", action="store_true", help="fetch and parse, print counts, load nothing")
    ap.add_argument("--force", action="store_true", help="bypass the volume guard")
    args = ap.parse_args()

    log = Logger("sync_us_local_finance")
    cfg = yaml.safe_load((PIPELINE_ROOT / "configs" / "countries" / f"{args.country}.yaml").read_text())
    only = set(args.only.split(",")) if args.only else None
    sources = [s for s in cfg.get("sources", []) if s.get("type") in ADAPTERS and (not only or s["id"] in only)]
    if not sources:
        log.error("no matching local-finance source")
        return 2
    client = None if args.dry_run else get_bigquery_client()
    failures = 0
    for src in sources:
        log.section(f"{src['id']} ({src['type']})")
        try:
            for table, (rows, cols, url) in ADAPTERS[src["type"]](src, log).items():
                if args.dry_run:
                    first, n = None, 0
                    for r in rows:
                        first = first or r
                        n += 1
                    if not n:
                        raise RuntimeError(f"{table}: 0 rows parsed")
                    log.info(f"parsed {table}", extra=f"{n:,} rows × {len(cols)} columns")
                    log.info("sample", extra=json.dumps({c: first.get(c) for c in cols[:9]}, ensure_ascii=False)[:320])
                    continue
                load(client, cfg.get("bq_raw_dataset", "raw"), table, rows, cols, src.get("source", src["id"]),
                     url, args.force, log)
        except Exception as e:
            log.error(f"failed: {src['id']}", extra=str(e)[:500])
            failures += 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
