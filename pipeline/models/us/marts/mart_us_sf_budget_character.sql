-- =============================================================================
-- Mart: SF adopted budget by character — the economic altitude
--
-- Sources: core_us_sf_budget, int_us_sf_characters, core_us_sf_source_catalog.
-- Grain:  fiscal_year × side × character (26 spending / 20 revenue characters
--         per modern FY — the Paris "poste" analogue; revenue characters are
--         the most citizen-readable label set in the dataset).
--
-- FY2018 excluded (corrupted-drill year — mixed chart-of-accounts systems).
-- display_category (seed) drives UI placement: standard → ranked bars ·
-- internal → internal-mechanics block (IntraFund Transfers In, Expenditure
-- Recovery) · adjustment → ELU/ELS labeled lines · offset → Overhead and
-- Allocations. Negatives never enter share/length visuals.
-- =============================================================================

WITH by_character AS (
    SELECT
        fiscal_year,
        revenue_or_spending                              AS side,
        character_code,
        character,
        SUM(budget_amt)                                  AS total_usd,
        COUNT(DISTINCT IF(ABS(budget_amt) > 0.005, department_code, NULL))
                                                         AS n_departments,
        COUNT(*)                                         AS n_lines,
        LOGICAL_OR(is_transfer_adjustment)               AS is_transfer_adjustment
    FROM {{ ref('core_us_sf_budget') }}
    WHERE fiscal_year != 2018
    GROUP BY 1, 2, 3, 4
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
    c.character_code,
    c.character,
    g.gloss                                 AS character_gloss,
    g.display_category,
    g.provenance                            AS gloss_provenance,
    c.total_usd,
    c.n_departments,
    c.n_lines,
    c.is_transfer_adjustment,
    SAFE_DIVIDE(
        c.total_usd,
        SUM(c.total_usd) OVER (PARTITION BY c.fiscal_year, c.side)
    )                                       AS share_of_side,
    {{ us_sf_execution_status('c.fiscal_year', basis='budget') }}
                                            AS execution_status,
    pr.dataset_page_url                     AS source_url,
    pr.rows_updated_at                      AS source_rows_updated_at,
    'USD'                                   AS unit
FROM by_character c
LEFT JOIN {{ ref('int_us_sf_characters') }} g
    ON g.side = c.side
   AND g.character_code = c.character_code
CROSS JOIN provenance pr
