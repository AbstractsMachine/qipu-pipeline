-- =============================================================================
-- Mart: SF adopted budget, department × character cells — the fiche altitude
--
-- Sources: core_us_sf_budget, int_us_sf_characters (display
--          enrichment), core_us_sf_source_catalog (provenance).
-- Grain:  fiscal_year × side × department × character (the SF equivalent of
--         the Paris chapitre/poste fiche altitude — ~460 spending + ~330
--         revenue nonzero cells per modern FY, measured 2026-07-16).
--
-- FY2018 excluded (corrupted-drill year — see mart_us_sf_budget_dept).
-- Zero cells (|amount| ≤ $0.005) are dropped; transfer-adjustment cells are
-- KEPT and flagged is_transfer_adjustment so exports carry them as labeled
-- lines (never silently netted, never inside share/length visuals).
-- gloss/display_category only exist for modern-era character codes.
-- =============================================================================

WITH cells AS (
    SELECT
        fiscal_year,
        revenue_or_spending                              AS side,
        organization_group_code,
        department_code,
        department,
        character_code,
        character,
        SUM(budget_amt)                                  AS amount_usd,
        LOGICAL_OR(is_transfer_adjustment)               AS is_transfer_adjustment,
        COUNT(*)                                         AS n_lines
    FROM {{ ref('core_us_sf_budget') }}
    WHERE fiscal_year != 2018
    GROUP BY 1, 2, 3, 4, 5, 6, 7
    HAVING ABS(SUM(budget_amt)) > 0.005
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
    c.fiscal_year,
    c.side,
    c.organization_group_code,
    c.department_code,
    c.department,
    c.character_code,
    c.character,
    g.gloss                                 AS character_gloss,
    g.display_category,
    c.amount_usd,
    c.is_transfer_adjustment,
    c.n_lines,
    {{ us_sf_execution_status('c.fiscal_year', basis='budget') }}
                                            AS execution_status,
    pr.dataset_page_url                     AS source_url,
    pr.rows_updated_at                      AS source_rows_updated_at,
    'USD'                                   AS unit
FROM cells c
LEFT JOIN {{ ref('int_us_sf_characters') }} g
    ON g.side = c.side
   AND g.character_code = c.character_code
CROSS JOIN provenance pr
