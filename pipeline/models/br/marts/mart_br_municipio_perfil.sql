-- =============================================================================
-- Mart: what a French commune page shows beyond its spending, for every
-- município (2026-09-23) — what it builds (investment), what it owes (loans
-- and financing, and what servicing them cost), its staff costs, the three
-- local taxes, its mayor and council.
--
-- Grain: one row per município × ano (2017+), the mayor and seats repeated.
-- Sources: SICONFI DCA Anexo I-D (nature), balance sheet, Anexo I-C (taxes);
-- TSE (mayors 2012-2024, council seats 2024).
--
-- Mayor: the first ELECTION of the current run by the same person (civil name
-- compared without accents or case): elected in 2020 and 2024 → 2020. It is an
-- election year, never « in office since »: a vice-mayor who took over mid-term
-- (São Paulo, 2021) is only known here from the election he won. 2012 is the
-- oldest election synced: a run that starts there may start earlier.
-- =============================================================================

WITH nat AS (
    SELECT
        id_municipio, ano,
        SUM(IF(grupo = '4.4', pago, 0))            AS investimento,
        SUM(IF(grupo = '3.1', pago, 0))            AS pessoal,
        SUM(IF(grupo IN ('3.2', '4.6'), pago, 0))  AS servico_divida,
        SUM(IF(grupo IN ('3.0', '4.0'), pago, 0))  AS total_natureza
    FROM {{ ref('stg_br_siconfi_despesas_natureza') }}
    GROUP BY 1, 2
),
div AS (
    SELECT id_municipio, ano, SUM(valor) AS divida
    FROM {{ ref('stg_br_siconfi_divida') }}
    GROUP BY 1, 2
),
imp AS (
    SELECT
        id_municipio, ano,
        SUM(IF(imposto = 'iptu', liquida, 0)) AS iptu,
        SUM(IF(imposto = 'iss', liquida, 0))  AS iss,
        SUM(IF(imposto = 'itbi', liquida, 0)) AS itbi
    FROM {{ ref('stg_br_siconfi_impostos') }}
    GROUP BY 1, 2
),
pref AS (
    SELECT
        id_municipio, ano, nome, nome_urna, genero,
        UPPER(REGEXP_REPLACE(NORMALIZE(nome, NFD), r'\pM', '')) AS chave
    FROM {{ ref('stg_br_tse_prefeitos') }}
),
-- The current mayor (elected 2024) and how far back the same person's run goes.
atual AS (
    SELECT
        p24.id_municipio,
        p24.nome, p24.nome_urna, p24.genero,
        CASE
            WHEN p20.chave = p24.chave AND p16.chave = p24.chave AND p12.chave = p24.chave THEN 2012
            WHEN p20.chave = p24.chave AND p16.chave = p24.chave THEN 2016
            WHEN p20.chave = p24.chave THEN 2020
            ELSE 2024
        END AS prefeito_primeira_eleicao,
        p20.chave = p24.chave AND p16.chave = p24.chave AND p12.chave = p24.chave AS desde_ao_menos
    FROM pref p24
    LEFT JOIN pref p20 ON p20.id_municipio = p24.id_municipio AND p20.ano = 2020
    LEFT JOIN pref p16 ON p16.id_municipio = p24.id_municipio AND p16.ano = 2016
    LEFT JOIN pref p12 ON p12.id_municipio = p24.id_municipio AND p12.ano = 2012
    WHERE p24.ano = 2024
),
anos AS (
    SELECT id_municipio, ano FROM nat
    UNION DISTINCT SELECT id_municipio, ano FROM div
    UNION DISTINCT SELECT id_municipio, ano FROM imp
)

SELECT
    a.id_municipio,
    a.ano,
    n.investimento,
    n.pessoal,
    n.servico_divida,
    n.total_natureza,
    -- A negative balance (loans below their reducing accounts, ~50 municípios a
    -- year) or a tax whose deductions exceed what was collected is an entry
    -- artifact, not a figure a reader can use: left out, never shown as « −R$ ».
    IF(d.divida < 0, NULL, d.divida) AS divida,
    IF(i.iptu < 0, NULL, i.iptu) AS iptu,
    IF(i.iss < 0, NULL, i.iss) AS iss,
    IF(i.itbi < 0, NULL, i.itbi) AS itbi,
    p.nome            AS prefeito_nome,
    p.nome_urna       AS prefeito_nome_urna,
    p.genero          AS prefeito_genero,
    p.prefeito_primeira_eleicao,
    p.desde_ao_menos  AS prefeito_desde_ao_menos,
    v.vereadores
FROM anos a
LEFT JOIN nat n USING (id_municipio, ano)
LEFT JOIN div d USING (id_municipio, ano)
LEFT JOIN imp i USING (id_municipio, ano)
LEFT JOIN atual p USING (id_municipio)
LEFT JOIN {{ ref('stg_br_tse_vagas') }} v USING (id_municipio)
