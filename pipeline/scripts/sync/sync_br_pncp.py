#!/usr/bin/env python3
"""
Sync the contracts of every município from the PNCP (Portal Nacional de
Contratações Públicas, Lei 14.133/2021) into raw.br_pncp_contratos (EU).

The PNCP has no bulk download and no municipal filter on /v1/contratos : the
only way is the day-by-day publication window, 500 rows a page, ~40 s a page
(measured 2026-09-18 : 5 000 to 10 000 contracts a day, two thirds municipal,
HTTP 500 now and then that a retry clears). So :

  * one JSONL a day under pipeline/data/br_pncp/ (gitignored), municipal rows
    only (orgaoEntidade.esferaId = 'M'), flattened to the columns the models
    read ; a `.done` marker per day makes the run resumable ;
  * days are fetched by a pool of workers (--workers, 8 by default) ;
  * --load copies the JSONL to gs://qipu-communes-budget/_raw/br_pncp/ and
    loads them into raw.br_pncp_contratos with an explicit schema (replace).

Usage :
    python pipeline/scripts/sync/sync_br_pncp.py --since 2026-01-01
    python pipeline/scripts/sync/sync_br_pncp.py --since 2025-01-01 --until 2025-12-31 --workers 10
    python pipeline/scripts/sync/sync_br_pncp.py --load            # after the fetch
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
from datetime import date, datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent.parent
OUT = ROOT / "pipeline" / "data" / "br_pncp"
API = "https://pncp.gov.br/api/consulta/v1/contratos"
PAGE = 500
PROJECT = "open-data-france-484717"
RAW_TABLE = f"{PROJECT}:raw.br_pncp_contratos"
GCS = "gs://qipu-communes-budget/_raw/br_pncp"

SCHEMA = [
    ("numero_controle_pncp", "STRING"), ("sequencial", "INTEGER"), ("numero_retificacao", "INTEGER"),
    ("ano_contrato", "INTEGER"), ("numero_contrato", "STRING"), ("tipo_contrato", "STRING"), ("categoria_processo", "STRING"),
    ("objeto", "STRING"), ("valor_inicial", "FLOAT"), ("valor_global", "FLOAT"), ("valor_acumulado", "FLOAT"),
    ("data_assinatura", "STRING"), ("vigencia_inicio", "STRING"), ("vigencia_fim", "STRING"),
    ("data_publicacao", "STRING"), ("data_atualizacao_global", "STRING"),
    ("orgao_cnpj", "STRING"), ("orgao_nome", "STRING"), ("esfera", "STRING"), ("poder", "STRING"),
    ("unidade_codigo", "STRING"), ("unidade_nome", "STRING"), ("id_municipio", "STRING"), ("municipio_nome", "STRING"), ("uf", "STRING"),
    ("fornecedor_ni", "STRING"), ("fornecedor_nome", "STRING"), ("fornecedor_tipo", "STRING"),
    ("receita", "BOOLEAN"), ("dia_publicacao", "STRING"),
]


def flatten(r: dict, day: str) -> dict:
    o = r.get("orgaoEntidade") or {}
    u = r.get("unidadeOrgao") or {}
    tc = r.get("tipoContrato") or {}
    cp = r.get("categoriaProcesso") or {}
    return {
        "numero_controle_pncp": r.get("numeroControlePNCP"), "sequencial": r.get("sequencialContrato"), "numero_retificacao": r.get("numeroRetificacao"),
        "ano_contrato": r.get("anoContrato"), "numero_contrato": r.get("numeroContratoEmpenho"), "tipo_contrato": tc.get("nome"), "categoria_processo": cp.get("nome"),
        "objeto": r.get("objetoContrato"), "valor_inicial": r.get("valorInicial"), "valor_global": r.get("valorGlobal"), "valor_acumulado": r.get("valorAcumulado"),
        "data_assinatura": r.get("dataAssinatura"), "vigencia_inicio": r.get("dataVigenciaInicio"), "vigencia_fim": r.get("dataVigenciaFim"),
        "data_publicacao": r.get("dataPublicacaoPncp"), "data_atualizacao_global": r.get("dataAtualizacaoGlobal"),
        "orgao_cnpj": o.get("cnpj"), "orgao_nome": o.get("razaoSocial"), "esfera": o.get("esferaId"), "poder": o.get("poderId"),
        "unidade_codigo": u.get("codigoUnidade"), "unidade_nome": u.get("nomeUnidade"), "id_municipio": u.get("codigoIbge"), "municipio_nome": u.get("municipioNome"), "uf": u.get("ufSigla"),
        "fornecedor_ni": r.get("niFornecedor"), "fornecedor_nome": r.get("nomeRazaoSocialFornecedor"), "fornecedor_tipo": r.get("tipoPessoa"),
        "receita": r.get("receita"), "dia_publicacao": day,
    }


def get(qs: str, tries: int = 8) -> dict:
    delay = 3.0
    for i in range(tries):
        try:
            req = urllib.request.Request(f"{API}?{qs}", headers={"Accept": "application/json", "User-Agent": "qipu-sync/0.1 (contato@qipu.org)"})
            with urllib.request.urlopen(req, timeout=300) as r:
                body = r.read()
            return json.loads(body) if body else {}
        except Exception as e:  # HTTP 500, timeouts, truncated chunked bodies (http.client.IncompleteRead) : retry them all
            code = getattr(e, "code", None)
            if i == tries - 1:
                raise
            time.sleep(delay if code != 429 else delay * 4)
            delay = min(delay * 1.7, 60)
    return {}


def fetch_day(day: date) -> tuple[str, int, int]:
    d = day.strftime("%Y%m%d")
    iso = day.isoformat()
    done = OUT / f"{iso}.done"
    if done.exists():
        return iso, -1, -1
    first = get(f"dataInicial={d}&dataFinal={d}&pagina=1&tamanhoPagina={PAGE}")
    pages = int(first.get("totalPaginas") or 0)
    total = int(first.get("totalRegistros") or 0)
    rows = [flatten(r, iso) for r in first.get("data") or [] if (r.get("orgaoEntidade") or {}).get("esferaId") == "M"]
    for p in range(2, pages + 1):
        d2 = get(f"dataInicial={d}&dataFinal={d}&pagina={p}&tamanhoPagina={PAGE}")
        rows.extend(flatten(r, iso) for r in d2.get("data") or [] if (r.get("orgaoEntidade") or {}).get("esferaId") == "M")
    tmp = OUT / f"{iso}.jsonl.tmp"
    with tmp.open("w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    tmp.rename(OUT / f"{iso}.jsonl")
    done.write_text(f"{total} {len(rows)}\n")
    return iso, total, len(rows)


def load() -> None:
    files = sorted(OUT.glob("*.jsonl"))
    if not files:
        print("nothing to load"); return
    subprocess.run(["gsutil", "-m", "-q", "rm", "-r", GCS], check=False, capture_output=True)
    subprocess.run(["gsutil", "-m", "-q", "cp", *[str(f) for f in files], GCS + "/"], check=True)
    schema = ",".join(f"{n}:{t}" for n, t in SCHEMA)
    subprocess.run(["bq", "load", "--location=EU", "--replace", "--source_format=NEWLINE_DELIMITED_JSON", "--ignore_unknown_values", RAW_TABLE, f"{GCS}/*.jsonl", schema], check=True)
    print(f"loaded {len(files)} days into {RAW_TABLE}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", default="2026-01-01")
    ap.add_argument("--until", default=(date.today() - timedelta(days=1)).isoformat())
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--load", action="store_true", help="copy the JSONL to GCS and load raw.br_pncp_contratos ; without --since/--until does only that")
    ap.add_argument("--no-fetch", action="store_true")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if not args.no_fetch:
        start, end = date.fromisoformat(args.since), date.fromisoformat(args.until)
        days = [start + timedelta(days=i) for i in range((end - start).days + 1)]
        t0 = time.time(); done_n = 0; rows_n = 0
        failed: list[str] = []
        def safe(day: date) -> tuple[str, int, int]:
            # A day that fails after its retries is logged and left without its
            # marker : the next run picks it up. One bad day must not end the job.
            try:
                return fetch_day(day)
            except Exception as e:
                failed.append(day.isoformat())
                print(f"{day.isoformat()}: FAILED {type(e).__name__}: {str(e)[:100]}", flush=True)
                return day.isoformat(), -2, 0
        with cf.ThreadPoolExecutor(args.workers) as ex:
            for iso, total, kept in ex.map(safe, days):
                if total < 0:
                    continue
                done_n += 1; rows_n += kept
                print(f"{iso}: {total} contracts, {kept} municipal  |  {done_n}/{len(days)} days, {rows_n} rows, {round(time.time() - t0)} s", flush=True)
        if failed:
            print(f"{len(failed)} day(s) failed, rerun to retry: {' '.join(failed[:20])}", flush=True)
    if args.load:
        load()
    return 0


if __name__ == "__main__":
    sys.exit(main())
