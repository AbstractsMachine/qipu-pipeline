#!/usr/bin/env python3
"""
Backfill the PNCP contracts of a few public bodies, one contract at a time,
into raw.br_pncp_contratos_orgaos (EU) — Recife's before 2026 (2026-09-23).

The national feed (sync_br_pncp.py) walks /v1/contratos day by day for every
município : 36 hours for eight months. For one city's bodies there is a
cheaper door. /v1/contratos with cnpjOrgao times out (HTTP 504 at 70 s, even
for one month), but the integration API answers one contract instantly :

    GET https://pncp.gov.br/api/pncp/v1/orgaos/{cnpj}/contratos/{ano}/{sequencial}

A body numbers its PNCP contracts 1, 2, 3… within the control-number year
(the year of publication, not of signature). So for each (cnpj, ano) the
script walks the sequence in blocks and stops after two blocks with nothing
in them. 404 = no such number ; 410 = withdrawn (counted as seen, not kept).
The response has the same fields as the feed, flattened by the same function.

  * one JSONL per (cnpj, ano) under pipeline/data/br_pncp_orgaos/ (gitignored),
    a `.done` marker each, so a run resumes ;
  * --load copies them to gs://qipu-communes-budget/_raw/br_pncp_orgaos/ and
    loads raw.br_pncp_contratos_orgaos (replace), same schema as the feed.

stg_br_pncp_contratos unions this table with the feed and keeps one row per
numero_controle_pncp, so overlap with the feed (2026) is harmless.

Usage :
    python pipeline/scripts/sync/sync_br_pncp_orgaos.py --municipio 2611606 --anos 2021-2025
    python pipeline/scripts/sync/sync_br_pncp_orgaos.py --load
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sync_br_pncp import ROOT, PROJECT, SCHEMA, flatten  # noqa: E402

OUT = ROOT / "pipeline" / "data" / "br_pncp_orgaos"
API = "https://pncp.gov.br/api/pncp/v1/orgaos/{cnpj}/contratos/{ano}/{seq}"
RAW_TABLE = f"{PROJECT}:raw.br_pncp_contratos_orgaos"
GCS = "gs://qipu-communes-budget/_raw/br_pncp_orgaos"
BLOCK = 25


def one(cnpj: str, ano: int, seq: int, tries: int = 6) -> tuple[int, dict | None]:
    """(status, row) — 200 with the contract, 404/410 without, after retries on 5xx."""
    delay = 2.0
    for i in range(tries):
        try:
            req = urllib.request.Request(API.format(cnpj=cnpj, ano=ano, seq=seq),
                                         headers={"Accept": "application/json", "User-Agent": "qipu-sync/0.1 (contato@qipu.org)"})
            with urllib.request.urlopen(req, timeout=60) as r:
                return 200, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                return e.code, None
            if i == tries - 1:
                raise
        except Exception:
            if i == tries - 1:
                raise
        time.sleep(delay)
        delay = min(delay * 1.7, 30)
    return 0, None


def walk(cnpj: str, ano: int, pool: cf.ThreadPoolExecutor) -> tuple[int, int]:
    done = OUT / f"{cnpj}_{ano}.done"
    if done.exists():
        return -1, -1
    rows, seen, empty_blocks, start = [], 0, 0, 1
    while empty_blocks < 2 and start < 20000:
        seqs = list(range(start, start + BLOCK))
        res = list(pool.map(lambda s: one(cnpj, ano, s), seqs))
        hits = [r for st, r in res if st == 200 and r]
        seen_block = sum(1 for st, _ in res if st in (200, 410))
        seen += seen_block
        for r in hits:
            if (r.get("orgaoEntidade") or {}).get("esferaId") == "M":
                rows.append(flatten(r, (r.get("dataPublicacaoPncp") or "")[:10]))
        empty_blocks = 0 if seen_block else empty_blocks + 1
        start += BLOCK
    tmp = OUT / f"{cnpj}_{ano}.jsonl.tmp"
    with tmp.open("w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    tmp.rename(OUT / f"{cnpj}_{ano}.jsonl")
    done.write_text(f"{seen} {len(rows)}\n")
    return seen, len(rows)


def orgaos_of(municipio: str) -> list[str]:
    """The bodies of a município's executive that publish on the PNCP, read off the
    national feed (raw.br_pncp_contratos) — the Câmara (poder L) is left out.
    The município itself is published with poder N (« não se aplica »), not E."""
    q = (f"SELECT DISTINCT orgao_cnpj FROM `{PROJECT}.raw.br_pncp_contratos` "
         f"WHERE id_municipio = '{municipio}' AND esfera = 'M' AND COALESCE(poder, '') NOT IN ('L', 'J') ORDER BY 1")
    out = subprocess.run(["bq", "query", "--use_legacy_sql=false", "--format=csv", q], check=True, capture_output=True, text=True).stdout
    return [l.strip() for l in out.splitlines()[1:] if l.strip().isdigit()]


def load() -> None:
    files = sorted(OUT.glob("*.jsonl"))
    if not files:
        print("nothing to load"); return
    subprocess.run(["gsutil", "-m", "-q", "rm", "-r", GCS], check=False, capture_output=True)
    subprocess.run(["gsutil", "-m", "-q", "cp", *[str(f) for f in files], GCS + "/"], check=True)
    schema = ",".join(f"{n}:{t}" for n, t in SCHEMA)
    subprocess.run(["bq", "load", "--location=EU", "--replace", "--source_format=NEWLINE_DELIMITED_JSON", "--ignore_unknown_values", RAW_TABLE, f"{GCS}/*.jsonl", schema], check=True)
    print(f"loaded {len(files)} files into {RAW_TABLE}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--municipio", help="IBGE code; its executive bodies are read off the national feed")
    ap.add_argument("--cnpj", nargs="*", default=[], help="bodies to walk (added to --municipio's)")
    ap.add_argument("--anos", default="2021-2025", help="control-number years, e.g. 2021-2025")
    ap.add_argument("--workers", type=int, default=10)
    ap.add_argument("--load", action="store_true")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    cnpjs = sorted(set(args.cnpj) | set(orgaos_of(args.municipio) if args.municipio else []))
    a0, _, a1 = args.anos.partition("-")
    anos = list(range(int(a0), int(a1 or a0) + 1))
    t0 = time.time()
    with cf.ThreadPoolExecutor(args.workers) as pool:
        for cnpj in cnpjs:
            for ano in anos:
                try:
                    seen, kept = walk(cnpj, ano, pool)
                except Exception as e:
                    print(f"{cnpj} {ano}: FAILED {type(e).__name__}: {str(e)[:100]} — rerun to retry", flush=True)
                    continue
                if seen >= 0:
                    print(f"{cnpj} {ano}: {seen} numbers, {kept} contracts  |  {round(time.time() - t0)} s", flush=True)
    if args.load:
        load()
    return 0


if __name__ == "__main__":
    sys.exit(main())
