-- =============================================================================
-- Mart: SF adopted budget by organization group — the page's top altitude
--
-- Sources: core_us_sf_budget, core_us_sf_source_catalog (provenance).
-- Grain:  fiscal_year × side × organization group, FY2010-FY2027 (all years:
--         the 7 org groups and their labels are the ONLY dimension stable
--         across the FY2018 chart-of-accounts break — verified live
--         2026-07-16, docs/us/block-studies/1-budget.md §1).
--
-- Totals are NET (transfer-adjustment rows stay in, exposed separately as
-- transfer_adjustment_usd). share_of_side is the group's share of the NET
-- fiscal-year total on its side.
-- =============================================================================

WITH by_group AS (
    SELECT
        fiscal_year,
        revenue_or_spending                              AS side,
        organization_group_code,
        organization_group,
        SUM(budget_amt)                                  AS total_usd,
        SUM(IF(is_transfer_adjustment, budget_amt, 0))   AS transfer_adjustment_usd,
        COUNT(DISTINCT IF(ABS(budget_amt) > 0.005, department_code, NULL))
                                                         AS n_departments,
        COUNT(*)                                         AS n_lines
    FROM {{ ref('core_us_sf_budget') }}
    GROUP BY fiscal_year, revenue_or_spending, organization_group_code, organization_group
),

provenance AS (
    SELECT DISTINCT
        dataset_id,
        dataset_name,
        dataset_page_url,
        attribution,
        rows_updated_at
    FROM {{ ref('core_us_sf_source_catalog') }}
    WHERE source_id = 'sf_budget'
)

SELECT
    g.fiscal_year,
    g.side,
    g.organization_group_code,
    g.organization_group,
    g.total_usd,
    g.transfer_adjustment_usd,
    g.n_departments,
    g.n_lines,
    SAFE_DIVIDE(
        g.total_usd,
        SUM(g.total_usd) OVER (PARTITION BY g.fiscal_year, g.side)
    )                                       AS share_of_side,
    {{ us_sf_execution_status('g.fiscal_year', basis='budget') }}
                                            AS execution_status,
    pr.dataset_id                           AS source_dataset_id,
    pr.dataset_name                         AS source_name,
    pr.dataset_page_url                     AS source_url,
    pr.attribution                          AS source_attribution,
    pr.rows_updated_at                      AS source_rows_updated_at,
    'USD'                                   AS unit
FROM by_group g
CROSS JOIN provenance pr
