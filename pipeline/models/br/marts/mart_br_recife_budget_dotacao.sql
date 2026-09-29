-- =============================================================================
-- Mart: the voted budget by FUNÇÃO × ano — dotação inicial (the LOA, what the
-- Câmara voted) and dotação atualizada (after supplementary credits), next
-- to the executed spend the other marts carry.
--
-- Source: core_br_recife_funcional. The dotação columns are monthly
-- movements like pago/empenhado (verified 2026-09-18 : summed over the year
-- they give R$ 8,0 bi / 9,6 bi / 10,3 bi for 2024-2026, a twelfth of that per
-- month would not ; the mês=0 rows of 2024 carry none). Summing is right.
-- Grain:  ano × função. Feeds the budget page's year rail : the current,
-- unfinished year shows what was voted, hatched, instead of five months of
-- payments.
-- =============================================================================

WITH by_funcao AS (
    SELECT
        ano,
        funcao_codigo,
        funcao,
        SUM(dotacao_inicial)    AS dotacao_inicial,
        SUM(dotacao_atualizada) AS dotacao_atualizada
    FROM {{ ref('core_br_recife_funcional') }}
    WHERE funcao IS NOT NULL
    GROUP BY 1, 2, 3
),

provenance AS (
    SELECT
        ANY_VALUE(dataset_page_url) AS source_url,
        MAX(rows_updated_at)        AS rows_updated_at
    FROM {{ ref('core_br_recife_source_catalog') }}
    WHERE source_id LIKE 'funcional_%'
)

SELECT
    b.ano,
    b.funcao_codigo,
    b.funcao,
    b.dotacao_inicial,
    b.dotacao_atualizada,
    'BRL' AS unit,
    p.source_url,
    p.rows_updated_at AS source_rows_updated_at
FROM by_funcao b
CROSS JOIN provenance p
