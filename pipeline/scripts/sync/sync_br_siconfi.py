#!/usr/bin/env python3
"""
Copy the Brazilian long-tail sources from the Base dos Dados public mirror
(BigQuery, US region) into our raw dataset (EU region) — BigQuery cannot read
across regions, so a filtered copy is made in a US scratch dataset, then
copied table by table to raw (EU).

Tables (raw.*):
    br_siconfi_despesas_funcao   SICONFI DCA Anexo I-E, 2017+, three stages, coded contas
    br_siconfi_receitas          SICONFI DCA Anexo I-C, 2017+, gross realized + the three
                                 deduction stages, coded contas only (18-char id_conta_bd :
                                 the standard chart, ~17 % of the rows, every total and origin)
    br_bd_municipios             the 5 570 municípios (IBGE code, name, UF, regions)
    br_ibge_populacao            IBGE population estimates per município, 2017+
    br_siconfi_despesas_natureza SICONFI DCA Anexo I-D, 2017+, paid, the group level
                                 (staff, debt interest, other current, investment,
                                 financial, debt repayment) — « what it builds »
    br_siconfi_divida            SICONFI balance sheet, 2017+, loans and financing,
                                 short and long term — « what it owes »
    br_siconfi_impostos          SICONFI DCA Anexo I-C, 2017+, the three local taxes
                                 (IPTU, ISS, ITBI), gross and deductions, every level
                                 (their codes changed in 2018: matched by name)
    br_tse_prefeitos             TSE, the mayors elected in 2012, 2016, 2020, 2024
    br_tse_vagas                 TSE, the council seats per município (vereador)

Usage:
    python pipeline/scripts/sync/sync_br_siconfi.py [--only br_siconfi_receitas]
Then: dbt build --select stg_br_siconfi_despesas_funcao+ stg_br_siconfi_receitas+ stg_br_municipios+
"""

import argparse
import subprocess
import sys

PROJECT = "open-data-france-484717"
TMP = "raw_us_tmp"
RAW = "raw"

QUERIES = {
    "br_siconfi_despesas_funcao": (
        "SELECT ano, sigla_uf, id_municipio, estagio, portaria, conta, id_conta_bd, conta_bd, valor "
        "FROM `basedosdados.br_me_siconfi.municipio_despesas_funcao` "
        "WHERE ano >= 2017 AND id_conta_bd IS NOT NULL "
        "AND estagio IN ('Despesas Empenhadas', 'Despesas Liquidadas', 'Despesas Pagas')"
    ),
    "br_siconfi_receitas": (
        "SELECT ano, sigla_uf, id_municipio, estagio, conta, id_conta_bd, conta_bd, valor "
        "FROM `basedosdados.br_me_siconfi.municipio_receitas_orcamentarias` "
        "WHERE ano >= 2017 AND id_conta_bd IS NOT NULL AND id_conta_bd != '' "
        "AND estagio IN ('Receitas Brutas Realizadas', 'Deduções - FUNDEB', "
        "'Deduções - Transferências Constitucionais', 'Outras Deduções da Receita')"
    ),
    "br_bd_municipios": (
        "SELECT id_municipio, id_municipio_6, nome, capital_uf, id_uf, sigla_uf, nome_uf, nome_regiao, "
        "nome_mesorregiao, nome_microrregiao, nome_regiao_metropolitana "
        "FROM `basedosdados.br_bd_diretorios_brasil.municipio`"
    ),
    "br_siconfi_despesas_natureza": (
        "SELECT ano, sigla_uf, id_municipio, portaria, conta, valor "
        "FROM `basedosdados.br_me_siconfi.municipio_despesas_orcamentarias` "
        "WHERE ano >= 2017 AND estagio = 'Despesas Pagas' "
        "AND REGEXP_CONTAINS(portaria, r'^[34]\\.[0-9]\\.00\\.00\\.00(\\.00)?$')"
    ),
    "br_siconfi_divida": (
        "SELECT ano, sigla_uf, id_municipio, portaria, conta, valor "
        "FROM `basedosdados.br_me_siconfi.municipio_balanco_patrimonial` "
        "WHERE ano >= 2017 AND REGEXP_CONTAINS(portaria, r'^2\\.[12]\\.2\\.0\\.0\\.00\\.00$')"
    ),
    "br_siconfi_impostos": (
        "SELECT ano, sigla_uf, id_municipio, estagio, portaria, conta, valor "
        "FROM `basedosdados.br_me_siconfi.municipio_receitas_orcamentarias` "
        "WHERE ano >= 2017 AND estagio IN ('Receitas Brutas Realizadas', 'Outras Deduções da Receita') "
        "AND (UPPER(conta) LIKE '%PROPRIEDADE PREDIAL%' OR UPPER(conta) LIKE '%SERVIÇOS DE QUALQUER NATUREZA%' "
        "OR UPPER(conta) LIKE '%INTER VIVOS%')"
    ),
    "br_tse_prefeitos": (
        "SELECT r.ano, r.turno, r.id_municipio, r.resultado, c.nome, c.nome_urna, c.genero "
        "FROM `basedosdados.br_tse_eleicoes.resultados_candidato_municipio` r "
        "JOIN `basedosdados.br_tse_eleicoes.candidatos` c "
        "ON c.ano = r.ano AND c.sequencial = r.sequencial_candidato AND c.id_municipio = r.id_municipio "
        "WHERE r.ano IN (2012, 2016, 2020, 2024) AND LOWER(r.cargo) = 'prefeito' AND LOWER(r.resultado) LIKE 'eleito%'"
    ),
    "br_tse_vagas": (
        "SELECT ano, id_municipio, cargo, vagas FROM `basedosdados.br_tse_eleicoes.vagas` "
        "WHERE ano = 2024 AND LOWER(cargo) = 'vereador'"
    ),
    "br_ibge_populacao": (
        "SELECT ano, sigla_uf, id_municipio, populacao FROM `basedosdados.br_ibge_populacao.municipio` WHERE ano >= 2017"
    ),
}


def run(cmd: list[str]) -> None:
    print("$", " ".join(cmd[:6]), "…" if len(cmd) > 6 else "")
    subprocess.run(cmd, check=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default=None, help="comma-separated table names to copy (default: all)")
    args = ap.parse_args()
    only = set(args.only.split(",")) if args.only else None
    subprocess.run(["bq", "mk", "--location=US", "-d", f"{PROJECT}:{TMP}"], check=False, capture_output=True)
    for table, sql in QUERIES.items():
        if only and table not in only:
            continue
        run(["bq", "query", "--use_legacy_sql=false", "--location=US", "--replace",
             f"--destination_table={PROJECT}:{TMP}.{table}", sql])
        run(["bq", "cp", "-f", f"{PROJECT}:{TMP}.{table}", f"{PROJECT}:{RAW}.{table}"])
    print("done:", ", ".join(f"raw.{t}" for t in QUERIES if not only or t in only))
    return 0


if __name__ == "__main__":
    sys.exit(main())
