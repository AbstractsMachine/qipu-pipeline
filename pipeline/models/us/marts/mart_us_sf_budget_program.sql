-- =============================================================================
-- Mart: SF adopted budget by program — the operating/capital/admin strip
--
-- Sources: core_us_sf_budget, core_us_sf_source_catalog.
-- Grain:  fiscal_year × side × program.
--
-- WHY THIS IS A STRIP AND NOT A DRILL LEVEL (measured, docs/us/
-- block-studies/1-budget.md §1): from FY2019 the program dimension collapses
-- to ~10 generic activity tags (Operating / Capital / Administrative /
-- Maintenance…) — median 3 per department. Programs are NOT navigable
-- content in the modern era; they support exactly one operating/capital/
-- admin KPI strip. FY2010-FY2017 has 291-324 real department-specific
-- programs — a different, legacy taxonomy. n_programs_in_fy lets the export
-- decide whether the strip is renderable (modern years) or omitted (legacy
-- years), without hardcoding a year boundary. FY2018 excluded (mixed
-- systems).
-- =============================================================================

WITH by_program AS (
    SELECT
        fiscal_year,
        revenue_or_spending                              AS side,
        program_code,
        program,
        SUM(budget_amt)                                  AS total_usd,
        COUNT(*)                                         AS n_lines
    FROM {{ ref('core_us_sf_budget') }}
    WHERE fiscal_year != 2018
    GROUP BY 1, 2, 3, 4
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
    p.fiscal_year,
    p.side,
    p.program_code,
    p.program,
    p.total_usd,
    p.n_lines,
    COUNT(*) OVER (PARTITION BY p.fiscal_year, p.side)  AS n_programs_in_fy,
    SAFE_DIVIDE(
        p.total_usd,
        SUM(p.total_usd) OVER (PARTITION BY p.fiscal_year, p.side)
    )                                       AS share_of_side,
    {{ us_sf_execution_status('p.fiscal_year', basis='budget') }}
                                            AS execution_status,
    pr.dataset_page_url                     AS source_url,
    pr.rows_updated_at                      AS source_rows_updated_at,
    'USD'                                   AS unit
FROM by_program p
CROSS JOIN provenance pr
