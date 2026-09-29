-- =============================================================================
-- Mart: monthly execution curve — total pago/empenhado by ano × mês.
--
-- Source: core_br_recife_funcional (full executed spend). Feeds the budget
-- page's "ritmo de execução" time series. mês=0 (opening dotação, pago=0)
-- excluded from the curve.
-- =============================================================================

WITH by_mes AS (
    SELECT
        ano,
        mes,
        SUM(empenhado) AS empenhado,
        SUM(liquidado) AS liquidado,
        SUM(pago)      AS pago
    FROM {{ ref('core_br_recife_funcional') }}
    WHERE mes IS NOT NULL AND mes BETWEEN 1 AND 12
    GROUP BY 1, 2
),

provenance AS (
    SELECT
        ANY_VALUE(dataset_page_url) AS source_url,
        MAX(rows_updated_at)        AS rows_updated_at
    FROM {{ ref('core_br_recife_source_catalog') }}
    WHERE source_id LIKE 'funcional_%'
)

SELECT
    m.ano,
    m.mes,
    m.empenhado,
    m.liquidado,
    m.pago,
    'BRL' AS unit,
    p.source_url,
    p.rows_updated_at AS source_rows_updated_at
FROM by_mes m
CROSS JOIN provenance p
