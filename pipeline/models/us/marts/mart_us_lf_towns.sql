-- =============================================================================
-- Mart: one row per US town with a page — identity, Census link, population,
-- and the years and latest totals of each document. The manifest the site
-- ships, and the peers' denominator (per resident).
--
-- display_name: Indiana writes "BEECH GROVE CIVIL CITY", Iowa "ACKLEY" — the
-- type suffix goes and the casing is restored. slug = name-state
-- ("sutton-ma"); a collision inside a state appends the government key.
-- fiscal_year_note: MA and IA years end June 30, FL September 30, IN is the
-- calendar year.
-- =============================================================================

WITH page AS (
    SELECT * FROM {{ ref('mart_us_lf_town_budget') }}
),

totals AS (
    SELECT state, government_key, fiscal_year, document, SUM(amount_usd) AS total_usd
    FROM page
    GROUP BY 1, 2, 3, 4
),

actual AS (
    SELECT state, government_key,
           ARRAY_AGG(fiscal_year ORDER BY fiscal_year)                         AS actual_years,
           MAX(fiscal_year)                                                    AS actual_latest_year,
           ARRAY_AGG(total_usd ORDER BY fiscal_year DESC LIMIT 1)[OFFSET(0)]   AS actual_latest_usd
    FROM totals WHERE document = 'actual' AND total_usd > 0
    GROUP BY 1, 2
),

voted AS (
    SELECT state, government_key,
           ARRAY_AGG(fiscal_year ORDER BY fiscal_year)                         AS voted_years,
           MAX(fiscal_year)                                                    AS voted_latest_year,
           ARRAY_AGG(total_usd ORDER BY fiscal_year DESC LIMIT 1)[OFFSET(0)]   AS voted_latest_usd
    FROM totals WHERE document = 'voted_budget' AND total_usd > 0
    GROUP BY 1, 2
),

-- Massachusetts: the voted operating budget is a TOTAL (tax rate recap).
ma_voted AS (
    SELECT 'MA' AS state, dor_code AS government_key,
           ARRAY_AGG(fiscal_year ORDER BY fiscal_year)                                     AS voted_years,
           MAX(fiscal_year)                                                                AS voted_latest_year,
           ARRAY_AGG(operating_budget_usd ORDER BY fiscal_year DESC LIMIT 1)[OFFSET(0)]    AS voted_latest_usd
    FROM {{ ref('stg_us_ma_operating_budget') }}
    WHERE operating_budget_usd > 0
    GROUP BY 1, 2
),

-- Indiana: the all-funds voted budget (the page itself shows the general fund).
in_all_funds AS (
    SELECT government_key, fiscal_year AS in_all_funds_year, SUM(amount_usd) AS in_all_funds_voted_usd
    FROM {{ ref('core_us_lf_spending') }}
    WHERE state = 'IN' AND document = 'voted_budget' AND counts_in_total
    GROUP BY 1, 2
    QUALIFY ROW_NUMBER() OVER (PARTITION BY government_key ORDER BY fiscal_year DESC) = 1
),

pop AS (
    -- population of the most recent Census file the unit appears in
    SELECT unit_id, population, file_year AS population_file_year
    FROM {{ ref('stg_us_census_iuf_units') }}
    WHERE population > 0
    QUALIFY ROW_NUMBER() OVER (PARTITION BY unit_id ORDER BY file_year DESC) = 1
),

towns AS (
    SELECT
        g.state,
        g.government_key,
        g.government_name                                           AS source_name,
        INITCAP(TRIM(REGEXP_REPLACE(g.government_name, r'(?i) CIVIL (CITY|TOWN)$', ''))) AS display_name,
        CASE
            WHEN REGEXP_CONTAINS(g.government_name, r'(?i) CIVIL TOWN$') THEN 'town'
            WHEN REGEXP_CONTAINS(g.government_name, r'(?i) CIVIL CITY$') THEN 'city'
            WHEN g.state = 'MA' AND g.census_gov_type = 'township' THEN 'town'
            WHEN g.state = 'MA' THEN 'city'
            ELSE NULL
        END                                                         AS town_kind,
        g.match_status,
        g.census_unit_id,
        p.population,
        p.population_file_year
    FROM {{ ref('int_us_lf_government_match') }} g
    LEFT JOIN pop p ON p.unit_id = g.census_unit_id
),

slugged AS (
    SELECT *,
        CONCAT(TRIM(REGEXP_REPLACE(LOWER(NORMALIZE(display_name, NFD)), r'[^a-z0-9]+', '-'), '-'), '-', LOWER(state)) AS base_slug
    FROM towns
)

SELECT
    t.state,
    t.government_key,
    IF(COUNT(*) OVER (PARTITION BY t.base_slug) > 1,
       CONCAT(t.base_slug, '-', LOWER(REGEXP_REPLACE(t.government_key, r'[^A-Za-z0-9]+', ''))),
       t.base_slug)                                                 AS slug,
    t.display_name,
    t.source_name,
    t.town_kind,
    t.match_status,
    t.census_unit_id,
    t.population,
    t.population_file_year,
    CASE t.state WHEN 'IN' THEN 'calendar' WHEN 'FL' THEN 'ends_sep_30' ELSE 'ends_jun_30' END AS fiscal_year_end,
    a.actual_years,
    a.actual_latest_year,
    a.actual_latest_usd,
    SAFE_DIVIDE(a.actual_latest_usd, t.population)                  AS actual_latest_per_resident,
    COALESCE(v.voted_years, mv.voted_years)                         AS voted_years,
    COALESCE(v.voted_latest_year, mv.voted_latest_year)             AS voted_latest_year,
    COALESCE(v.voted_latest_usd, mv.voted_latest_usd)               AS voted_latest_usd,
    t.state = 'MA'                                                  AS voted_is_total_only,
    i.in_all_funds_year,
    i.in_all_funds_voted_usd
FROM slugged t
LEFT JOIN actual a     USING (state, government_key)
LEFT JOIN voted v      USING (state, government_key)
LEFT JOIN ma_voted mv  USING (state, government_key)
LEFT JOIN in_all_funds i ON t.state = 'IN' AND i.government_key = t.government_key
WHERE a.actual_latest_year IS NOT NULL OR COALESCE(v.voted_latest_year, mv.voted_latest_year) IS NOT NULL
