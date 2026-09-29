-- =============================================================================
-- Staging: SICONFI DCA Anexo I-C, every município — receitas orçamentárias
-- realizadas, by stage (2026-09-18, the Brazilian long tail, second block).
--
-- Source: raw.br_siconfi_receitas — a filtered copy of the Base dos Dados
--         mirror basedosdados.br_me_siconfi.municipio_receitas_orcamentarias
--         (US region ; copied to EU by scripts/sync/sync_br_siconfi.py), coded
--         rows only. Coverage measured 2026-09-18 on the total row : 2017→2024
--         = 5 536–5 562 municípios each year, 2025 = 5 446.
-- Grain:  ano × município × estágio × conta.
-- Codes:  id_conta_bd = '1.A.B.C.D.EE.FF.GG' (18 characters), the standard
--         chart of revenue accounts. '1.0.0.0.0.00.00.00' is the total
--         "Receitas (exceto intraorçamentárias)" ; '1.1' Receitas Correntes,
--         '1.2' Receitas de Capital ; the third segment is the origem
--         (1.1.1 Impostos, taxas e contribuições ; 1.1.7 Transferências
--         correntes ; 1.2.1 Operações de crédito…), the fourth its detail
--         (1.1.1.1 Impostos, 1.1.1.2 Taxas). '1.7' and '1.8' are the
--         intraorçamentárias, outside the total, left out.
-- Stages: 'Receitas Brutas Realizadas' is the gross ; the three deduction
--         stages (FUNDEB, transferências constitucionais, outras) are
--         subtracted in core to give the net revenue SICONFI calls
--         "receita realizada".
-- =============================================================================

WITH src AS (
    SELECT
        ano,
        id_municipio,
        sigla_uf,
        estagio,
        id_conta_bd,
        conta_bd,
        SPLIT(id_conta_bd, '.') AS seg,
        valor
    FROM {{ source('br_siconfi_raw', 'br_siconfi_receitas') }}
    WHERE ano >= 2017
      AND id_conta_bd IS NOT NULL AND id_conta_bd != ''
      AND valor IS NOT NULL
      AND LENGTH(id_conta_bd) = 18
      AND SPLIT(id_conta_bd, '.')[SAFE_OFFSET(1)] IN ('0', '1', '2')
)

SELECT
    ano,
    id_municipio,
    sigla_uf,
    estagio,
    id_conta_bd,
    conta_bd,
    -- The depth of the account : 0 = the total, 1 = correntes / capital,
    -- 2 = the origem, 3 = its detail, deeper = the named lines below.
    CASE
        WHEN seg[SAFE_OFFSET(1)] = '0' THEN 0
        WHEN seg[SAFE_OFFSET(2)] = '0' THEN 1
        WHEN seg[SAFE_OFFSET(3)] = '0' THEN 2
        WHEN seg[SAFE_OFFSET(4)] = '0' AND seg[SAFE_OFFSET(5)] = '00' THEN 3
        ELSE 4
    END AS nivel,
    CONCAT(seg[SAFE_OFFSET(0)], '.', seg[SAFE_OFFSET(1)]) AS grupo_codigo,
    CONCAT(seg[SAFE_OFFSET(0)], '.', seg[SAFE_OFFSET(1)], '.', seg[SAFE_OFFSET(2)]) AS origem_codigo,
    CONCAT(seg[SAFE_OFFSET(0)], '.', seg[SAFE_OFFSET(1)], '.', seg[SAFE_OFFSET(2)], '.', seg[SAFE_OFFSET(3)]) AS detalhe_codigo,
    valor
FROM src
