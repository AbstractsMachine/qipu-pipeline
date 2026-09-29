-- =============================================================================
-- Mart: budget executed by FUNÇÃO (and subfunção) × ano — the budget page's
-- primary altitude, "para que serve o dinheiro" (what the money is for).
--
-- Source: core_br_recife_funcional (Despesa Funcional Programática).
-- Grain:  ano × função × subfunção. pago/empenhado summed over months
--         (monthly-incremental, verified). 2024 Σpago = R$8.97 bn = the full
--         executed municipal spend (broader than the credor spine).
-- Provenance (source_url + as_of) carried from core_br_recife_source_catalog.
-- =============================================================================

WITH by_funcao AS (
    SELECT
        ano,
        funcao_codigo,
        funcao,
        subfuncao_codigo,
        subfuncao,
        SUM(empenhado) AS empenhado,
        SUM(liquidado) AS liquidado,
        SUM(pago)      AS pago,
        COUNT(*)       AS n_linhas
    FROM {{ ref('core_br_recife_funcional') }}
    WHERE funcao IS NOT NULL
    GROUP BY 1, 2, 3, 4, 5
),

provenance AS (
    SELECT
        ANY_VALUE(dataset_title)     AS source_name,
        ANY_VALUE(dataset_page_url)  AS source_url,
        ANY_VALUE(portal_name)       AS source_portal,
        ANY_VALUE(license_title)     AS source_license,
        MAX(rows_updated_at)         AS rows_updated_at
    FROM {{ ref('core_br_recife_source_catalog') }}
    WHERE source_id LIKE 'funcional_%'
)

SELECT
    b.ano,
    b.funcao_codigo,
    b.funcao,
    b.subfuncao_codigo,
    b.subfuncao,
    b.empenhado,
    b.liquidado,
    b.pago,
    b.n_linhas,
    SAFE_DIVIDE(b.pago, SUM(b.pago) OVER (PARTITION BY b.ano)) AS share_of_year,
    'BRL'                 AS unit,
    p.source_name,
    p.source_url,
    p.source_portal,
    p.source_license,
    p.rows_updated_at     AS source_rows_updated_at
FROM by_funcao b
CROSS JOIN provenance p
