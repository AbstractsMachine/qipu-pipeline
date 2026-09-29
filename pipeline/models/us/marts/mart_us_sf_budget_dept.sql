-- =============================================================================
-- Mart: SF adopted budget by department — the page's second altitude
--
-- Sources: core_us_sf_budget, int_us_sf_departments (display enrichment),
--          core_us_sf_source_catalog (provenance).
-- Grain:  fiscal_year × side × department.
--
-- FY2018 IS EXCLUDED: it is a corrupted-drill year — the budget dataset
-- mixes both chart-of-accounts systems and carries DUPLICATE department
-- identities ("Public Health" and "DPH Public Health" simultaneously) plus
-- ~21k zero-value modern-code skeleton rows (measured, docs/us/
-- block-studies/1-budget.md §7). Citywide/org-group FY2018 series live in
-- mart_us_sf_budget_by_year / mart_us_sf_budget_org_group.
--
-- total_usd is NET (embedded negative transfer-adjustment rows stay in —
-- attached at dept level across ~44 depts); transfer_adjustment_usd exposes
-- that netting per department so the UI can carry it as a labeled line.
-- display_name (seed enrichment) only exists for modern-era codes; the
-- source label is always carried alongside, never overwritten.
-- =============================================================================

WITH by_dept AS (
    SELECT
        fiscal_year,
        revenue_or_spending                              AS side,
        organization_group_code,
        organization_group,
        department_code,
        department,
        SUM(budget_amt)                                  AS total_usd,
        SUM(IF(is_transfer_adjustment, budget_amt, 0))   AS transfer_adjustment_usd,
        COUNT(DISTINCT IF(ABS(budget_amt) > 0.005, character_code, NULL))
                                                         AS n_characters,
        COUNT(*)                                         AS n_lines
    FROM {{ ref('core_us_sf_budget') }}
    WHERE fiscal_year != 2018
    GROUP BY 1, 2, 3, 4, 5, 6
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
    d.fiscal_year,
    d.side,
    d.organization_group_code,
    d.organization_group,
    d.department_code,
    d.department,
    n.display_name                          AS department_display_name,
    n.provenance                            AS display_name_provenance,
    d.total_usd,
    d.transfer_adjustment_usd,
    d.total_usd - d.transfer_adjustment_usd AS total_excl_transfer_adjustment_usd,
    d.n_characters,
    d.n_lines,
    SAFE_DIVIDE(
        d.total_usd,
        SUM(d.total_usd) OVER (PARTITION BY d.fiscal_year, d.side)
    )                                       AS share_of_side,
    {{ us_sf_execution_status('d.fiscal_year', basis='budget') }}
                                            AS execution_status,
    pr.dataset_id                           AS source_dataset_id,
    pr.dataset_name                         AS source_name,
    pr.dataset_page_url                     AS source_url,
    pr.attribution                          AS source_attribution,
    pr.rows_updated_at                      AS source_rows_updated_at,
    'USD'                                   AS unit
FROM by_dept d
LEFT JOIN {{ ref('int_us_sf_departments') }} n
    ON n.department_code = d.department_code
CROSS JOIN provenance pr
