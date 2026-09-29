-- =============================================================================
-- Mart: SF adopted budget, department × character × object cells — the
-- raw line-item detail one level below the fiche altitude
--
-- Sources: core_us_sf_budget, core_us_sf_source_catalog (provenance).
-- Grain:  fiscal_year × side × department × character × object.
--
-- WHY THIS IS RAW DETAIL, NOT A HEADLINE DRILL LEVEL (measured, docs/us/
-- block-studies/1-budget.md §1, §2): object labels are only ~25-50%
-- plain-English on a random sample ("Sciap (Specialized Care) Svcs",
-- "ITO To 5L-Lagna Hnda Hosptl Fd") — no gloss enrichment exists for this
-- dimension. dept×object is 2,633 cells FY2026, ~5.7x the dept×character
-- cell count — too many to rank as a fiche section, right as an expandable
-- "line items" list underneath a character the user has already selected.
--
-- FY2018 excluded (corrupted-drill year — see mart_us_sf_budget_dept).
-- Zero cells (|amount| ≤ $0.005) are dropped; transfer-adjustment cells are
-- KEPT and flagged, same doctrine as mart_us_sf_budget_dept_character.
-- =============================================================================

WITH cells AS (
    SELECT
        fiscal_year,
        revenue_or_spending                              AS side,
        department_code,
        department,
        character_code,
        character,
        object_code,
        object,
        SUM(budget_amt)                                  AS amount_usd,
        LOGICAL_OR(is_transfer_adjustment)               AS is_transfer_adjustment
    FROM {{ ref('core_us_sf_budget') }}
    WHERE fiscal_year != 2018
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
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
    c.fiscal_year,
    c.side,
    c.department_code,
    c.department,
    c.character_code,
    c.character,
    c.object_code,
    c.object,
    c.amount_usd,
    c.is_transfer_adjustment,
    pr.dataset_page_url                     AS source_url,
    pr.rows_updated_at                      AS source_rows_updated_at,
    'USD'                                   AS unit
FROM cells c
CROSS JOIN provenance pr
