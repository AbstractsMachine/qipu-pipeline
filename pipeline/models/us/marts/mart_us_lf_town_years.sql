-- =============================================================================
-- Mart: yearly totals per town and document — the year rail of a town page.
-- Voted totals come from the categorised lines, except Massachusetts, whose
-- voted budget exists only as a total (tax rate recap).
-- =============================================================================

WITH from_lines AS (
    SELECT state, government_key, fiscal_year, document, SUM(amount_usd) AS total_usd
    FROM {{ ref('mart_us_lf_town_budget') }}
    GROUP BY 1, 2, 3, 4
),

ma_voted AS (
    SELECT 'MA' AS state, dor_code AS government_key, fiscal_year, 'voted_budget' AS document,
           operating_budget_usd AS total_usd
    FROM {{ ref('stg_us_ma_operating_budget') }}
)

SELECT * FROM from_lines WHERE total_usd > 0
UNION ALL
SELECT * FROM ma_voted WHERE total_usd > 0
