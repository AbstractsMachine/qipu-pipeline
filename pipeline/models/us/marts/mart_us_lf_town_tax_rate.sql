-- =============================================================================
-- Mart: the property tax rate a US town sets, town × year — the "Taxe
-- foncière" block of the French commune page. Each state's own figure and
-- unit, never converted:
--   MA  residential rate, $ per $1,000 of assessed value (and the commercial
--       rate: split-rate towns tax businesses more), DLS, by fiscal year
--   IA  the city's total levy rate, $ per $1,000 of taxable value, and its
--       debt service levy, DOM, by fiscal year
--   IN  the civil city's / town's certified rate, $ per $100 of assessed value
--       (the sum over its funds), and its levy, DLGF, by the year taxes are PAID
--   FL  the city millage, $ per $1,000 of taxable value, and taxes levied, DOR
-- California sets no city rate (1% base under Prop 13, voter overrides by tax
-- rate area): no figure.
-- Florida and Iowa files name the town; they meet the town list on the
-- normalised name inside the state (as the Census match does).
-- =============================================================================

WITH towns AS (
    SELECT state, government_key,
           {{ us_lf_name_key('source_name') }}                  AS name_exact,
           {{ us_lf_name_key('source_name', strip_type=true) }} AS name_key
    FROM {{ ref('mart_us_lf_towns') }}
    WHERE state IN ('FL')
),

ma AS (
    SELECT 'MA' AS state, dor_code AS government_key, fiscal_year AS year,
           residential_rate AS rate, 'per_1000' AS rate_unit, commercial_rate,
           CAST(NULL AS NUMERIC) AS debt_service_rate, CAST(NULL AS NUMERIC) AS levy_usd
    FROM {{ ref('stg_us_ma_tax_rates') }}
),

ia AS (
    SELECT 'IA', city_code, fiscal_year, total_rate, 'per_1000', CAST(NULL AS NUMERIC),
           debt_service_rate, CAST(NULL AS NUMERIC)
    FROM {{ ref('stg_us_ia_city_tax_rates') }}
    WHERE total_rate > 0
),

inn AS (
    SELECT 'IN', CONCAT(county_code, '-', unit_code), pay_year, SUM(rate_per_100), 'per_100',
           CAST(NULL AS NUMERIC), CAST(NULL AS NUMERIC), SUM(levy_usd)
    FROM {{ ref('stg_us_in_certified_rates') }}
    WHERE unit_type_code = '3'
    GROUP BY 2, 3
    HAVING SUM(rate_per_100) > 0
),

fl AS (
    SELECT 'FL', t.government_key, f.tax_year, f.millage, 'per_1000',
           CAST(NULL AS NUMERIC), CAST(NULL AS NUMERIC), f.taxes_levied_usd
    FROM {{ ref('stg_us_fl_municipal_millage') }} f
    JOIN towns t ON t.state = 'FL'
     AND (t.name_exact = {{ us_lf_name_key('f.municipality') }}
          OR t.name_key = {{ us_lf_name_key('f.municipality', strip_type=true) }})
    WHERE f.millage > 0
    -- the exact name wins; the name without its type word ("City of") is the
    -- fallback — two towns can differ by it alone (Iowa: Rockwell, Rockwell City)
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY t.government_key, f.tax_year
        ORDER BY IF(t.name_exact = {{ us_lf_name_key('f.municipality') }}, 0, 1)) = 1
)

SELECT * FROM ma
UNION ALL SELECT * FROM ia
UNION ALL SELECT * FROM inn
UNION ALL SELECT * FROM fl
