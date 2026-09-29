-- =============================================================================
-- Mart: one row per município with its identity, population and the yearly
-- totals (pago, empenhado) — the manifest the site ships, and the peers'
-- denominator (pago per inhabitant, latest year).
-- =============================================================================

WITH tot AS (
    SELECT id_municipio, ano, pago, empenhado
    FROM {{ ref('core_br_municipio_despesas') }}
    WHERE funcao_codigo = '00' AND subfuncao_codigo = '000' AND pago > 0
),
agg AS (
    SELECT
        id_municipio,
        ARRAY_AGG(STRUCT(ano, pago, empenhado) ORDER BY ano) AS anos,
        MAX(ano) AS ano_mais_recente,
        MIN(ano) AS ano_inicio,
        ARRAY_AGG(pago ORDER BY ano DESC LIMIT 1)[OFFSET(0)] AS pago_recente
    FROM tot
    GROUP BY 1
),
-- The net revenue (gross minus the deductions) of the latest year that has
-- one, from the revenue side (2026-09-18).
rec AS (
    SELECT
        id_municipio,
        ARRAY_AGG(ano ORDER BY ano DESC LIMIT 1)[OFFSET(0)] AS receita_ano,
        ARRAY_AGG(liquida ORDER BY ano DESC LIMIT 1)[OFFSET(0)] AS receita_recente
    FROM {{ ref('core_br_municipio_receitas') }}
    WHERE nivel = 0 AND liquida > 0
    GROUP BY 1
),

ct AS (
    -- The contracts on the PNCP (2026-09-18) : the latest year with contracts,
    -- its count and its total.
    SELECT id_municipio, ano AS contratos_ano, n_ano AS contratos_n, valor_ano AS contratos_valor
    FROM {{ ref('mart_br_municipio_contratos') }}
    WHERE rank_ano = 1
    QUALIFY ROW_NUMBER() OVER (PARTITION BY id_municipio ORDER BY ano DESC) = 1
)

SELECT
    m.id_municipio,
    m.nome,
    m.sigla_uf,
    m.nome_uf,
    m.nome_regiao,
    m.capital_uf,
    m.populacao,
    m.populacao_ano,
    m.slug,
    a.anos,
    a.ano_mais_recente,
    a.ano_inicio,
    a.pago_recente,
    SAFE_DIVIDE(a.pago_recente, m.populacao) AS pago_hab,
    r.receita_ano,
    r.receita_recente,
    SAFE_DIVIDE(r.receita_recente, m.populacao) AS receita_hab,
    c.contratos_ano,
    c.contratos_n,
    c.contratos_valor
FROM {{ ref('core_br_municipios') }} m
JOIN agg a USING (id_municipio)
LEFT JOIN rec r USING (id_municipio)
LEFT JOIN ct c USING (id_municipio)
