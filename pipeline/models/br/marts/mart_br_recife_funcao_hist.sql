-- =============================================================================
-- Mart: a função of Recife's budget over 2002-2023, from the older series
-- (stg_br_recife_despesa_orc). Feeds the função fiche's longer year rail, its
-- « Sob que forma » (what the money bought) and « Quem gasta » (which órgão).
--
-- Grain: ano × função × corte × chave, where corte is
--   'total'   — one row per ano × função (chave = NULL)
--   'forma'   — the natureza read in plain words (chave below)
--   'orgao'   — the órgão that spent it (chave = órgão name as published)
--
-- The « forma » reading of the natureza (grupo + elemento + modalidade de
-- aplicação), the Recife counterpart of Paris's « Sous quelle forme » :
--   pessoal        grupo 1 — salaries, pensions and their charges
--   divida         grupos 2 and 6 — interest and repayment
--   obras          grupo 4 — works, equipment, buildings
--   transferencias modalidade 50 (private non-profits) or elementos 41/42/43/45
--                  — contributions and grants
--   auxilios       elementos 08/18/32/48 — cash and in-kind aid to people
--   compras        elementos 14/30/33/35/36/37/39/40 — goods and services bought
--   outros         everything else (court orders, prior-year bills, taxes…)
-- Pago = valor_pago summed over the year's movements (the series records each
-- payment and its reversals as signed movements).
-- =============================================================================

WITH base AS (
    SELECT
        ano,
        funcao_codigo,
        funcao,
        orgao,
        CASE
            WHEN grupo_codigo = '1' THEN 'pessoal'
            WHEN grupo_codigo IN ('2', '6') THEN 'divida'
            WHEN grupo_codigo = '4' THEN 'obras'
            WHEN modalidade_aplicacao_codigo = '50'
              OR elemento_codigo IN ('41', '42', '43', '45') THEN 'transferencias'
            WHEN elemento_codigo IN ('08', '18', '32', '48') THEN 'auxilios'
            WHEN elemento_codigo IN ('14', '30', '33', '35', '36', '37', '39', '40') THEN 'compras'
            ELSE 'outros'
        END AS forma,
        pago
    FROM {{ ref('stg_br_recife_despesa_orc') }}
    WHERE funcao IS NOT NULL AND ano BETWEEN 2002 AND 2023
),

-- The função's name as the latest year writes it (a code keeps one name, but the
-- spelling drifts across 22 years of exports).
nome AS (
    SELECT funcao_codigo, ARRAY_AGG(funcao ORDER BY ano DESC LIMIT 1)[OFFSET(0)] AS funcao
    FROM base
    GROUP BY 1
),

cortes AS (
    SELECT ano, funcao_codigo, 'total' AS corte, CAST(NULL AS STRING) AS chave, SUM(pago) AS pago FROM base GROUP BY 1, 2
    UNION ALL
    SELECT ano, funcao_codigo, 'forma', forma, SUM(pago) FROM base GROUP BY 1, 2, 4
    UNION ALL
    SELECT ano, funcao_codigo, 'orgao', orgao, SUM(pago) FROM base WHERE orgao IS NOT NULL GROUP BY 1, 2, 4
)

SELECT
    c.ano,
    c.funcao_codigo,
    n.funcao,
    c.corte,
    c.chave,
    c.pago,
    'BRL' AS unit
FROM cortes c
JOIN nome n USING (funcao_codigo)
WHERE c.pago IS NOT NULL
