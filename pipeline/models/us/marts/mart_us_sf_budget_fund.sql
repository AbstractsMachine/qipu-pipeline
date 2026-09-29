-- =============================================================================
-- Mart: SF adopted budget by fund type × fund category
--
-- Sources: core_us_sf_budget, core_us_sf_source_catalog.
-- Grain:  fiscal_year × side × fund_type × fund_category (~35 nonzero rows
--         per modern FY).
--
-- The pair that matters is fund_category — Operating vs Continuing Projects
-- vs Grants/Annual Projects: it drives the budget-vs-actual comparison
-- perimeter (only Operating reconciles; see mart_us_sf_budget_vs_actual),
-- not page navigation. All fiscal years kept: FY2018 uses the legacy fund
-- taxonomy (different fund_type names) but is internally consistent
-- (verified live 2026-07-16).
-- =============================================================================

WITH by_fund AS (
    SELECT
        fiscal_year,
        revenue_or_spending                              AS side,
        fund_type_code,
        fund_type,
        fund_category_code,
        fund_category,
        SUM(budget_amt)                                  AS total_usd,
        COUNT(DISTINCT fund_code)                        AS n_funds,
        COUNT(*)                                         AS n_lines
    FROM {{ ref('core_us_sf_budget') }}
    GROUP BY 1, 2, 3, 4, 5, 6
    HAVING ABS(SUM(budget_amt)) > 0.005
),

provenance AS (
    SELECT DISTINCT
        dataset_page_url,
        rows_updated_at
    FROM {{ ref('core_us_sf_source_catalog') }}
    WHERE source_id = 'sf_budget'
)

SELECT
    f.fiscal_year,
    f.side,
    f.fund_type_code,
    f.fund_type,
    f.fund_category_code,
    f.fund_category,
    f.total_usd,
    f.n_funds,
    f.n_lines,
    {{ us_sf_execution_status('f.fiscal_year', basis='budget') }}
                                            AS execution_status,
    pr.dataset_page_url                     AS source_url,
    pr.rows_updated_at                      AS source_rows_updated_at,
    'USD'                                   AS unit
FROM by_fund f
CROSS JOIN provenance pr
