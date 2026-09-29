-- =============================================================================
-- Mart: SF budget by fiscal year — net adopted totals per side
--
-- Sources: core_us_sf_budget, core_us_sf_population (per-resident),
--          core_us_sf_source_catalog (provenance — dataset page URL +
--          rows_updated_at as the export `as_of`).
-- Grain:  fiscal_year × side (Revenue | Spending), FY2010-FY2027.
--
-- The totals are NET because the negative "Transfer Adjustment" rows stay
-- in (docs/us/API-RECON.md §A.1) — naive SUM(budget_amt) is correct
-- precisely because of them; transfer_adjustment_usd shows how much they
-- net out per year. Revenue = Spending per FY within $10 (balanced budget,
-- tested in tests/us/assert_us_sf_budget_revenue_equals_spending.sql).
--
-- per_resident_usd only exists where a same-year Census estimate exists
-- (2020-2025); SF FY N ends Jun 30 of year N, so the July 1 estimate of
-- year N is the FY-end population.
-- =============================================================================

WITH budget AS (
    SELECT
        fiscal_year,
        revenue_or_spending                              AS side,
        SUM(budget_amt)                                  AS total_usd,
        SUM(IF(is_transfer_adjustment, budget_amt, 0))   AS transfer_adjustment_usd,
        COUNT(*)                                         AS n_lines,
        LOGICAL_AND(is_fiscal_year_complete)             AS is_fiscal_year_complete
    FROM {{ ref('core_us_sf_budget') }}
    GROUP BY fiscal_year, revenue_or_spending
),

pop AS (
    SELECT year, as_of_date, population, source, source_url
    FROM {{ ref('core_us_sf_population') }}
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
    b.fiscal_year,
    b.side,
    b.total_usd,
    b.transfer_adjustment_usd,
    b.n_lines,
    b.is_fiscal_year_complete,
    -- Block 1: the calendar boolean above misleads (it flags the newest
    -- ended FY "complete" while the accounting close runs for months) —
    -- exports and the UI read execution_status instead (boolean kept,
    -- additive; see macros/us_sf_execution_status.sql).
    {{ us_sf_execution_status('b.fiscal_year', basis='budget') }}
                                            AS execution_status,
    SAFE_DIVIDE(b.total_usd, p.population)  AS per_resident_usd,
    p.population,
    p.year                                  AS population_year,
    p.as_of_date                            AS population_as_of,
    p.source                                AS population_source,
    p.source_url                            AS population_source_url,
    pr.dataset_id                           AS source_dataset_id,
    pr.dataset_name                         AS source_name,
    pr.dataset_page_url                     AS source_url,
    pr.attribution                          AS source_attribution,
    pr.rows_updated_at                      AS source_rows_updated_at,
    'USD'                                   AS unit
FROM budget b
LEFT JOIN pop p
    ON p.year = b.fiscal_year
CROSS JOIN provenance pr
