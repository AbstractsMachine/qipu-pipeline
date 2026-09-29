-- =============================================================================
-- Intermediate: US local revenue lines, every source in one shape (unmapped)
--
-- Grain: one row per (source_system, government_key, fiscal_year, document,
--        source_key[, detail]) — `line_id` is unique.
--
-- The mirror of int_us_lf_spending_lines, with the same scope per state so a
-- page sets what came in against what went out on one perimeter:
--   MA  general fund (Schedule A revenues), actuals
--   IA  all funds, budget and actuals in one nomenclature (dataset 928)
--   FL  the town's OWN funds — fiduciary and internal service funds left out,
--       as on the spending side
--   CA  the city's own funds — internal service fund and conduit financing
--       mapped to counts_in_total = false in the seed
-- Indiana has no revenue source loaded yet: its pages show spending only.
--
-- Borrowing and transfers between funds stay in as lines (so coverage can be
-- measured) but the seed marks them counts_in_total = false: a bond is money
-- the town will repay, a transfer is the same dollar counted twice.
-- An actual not filed yet is ABSENT, not zero (as for spending).
-- =============================================================================

WITH ma AS (
    SELECT dor_code, municipality, fiscal_year, col, amount
    FROM {{ ref('stg_us_ma_general_fund_revenues') }}
    UNPIVOT (amount FOR col IN (
        taxes_usd                    AS 'taxes',
        service_charges_usd          AS 'service_charges',
        licenses_and_permits_usd     AS 'licenses_and_permits',
        federal_revenue_usd          AS 'federal_revenue',
        state_revenue_usd            AS 'state_revenue',
        other_governments_usd        AS 'other_governments',
        special_assessments_usd      AS 'special_assessments',
        fines_and_forfeitures_usd    AS 'fines_and_forfeitures',
        miscellaneous_usd            AS 'miscellaneous',
        other_financing_sources_usd  AS 'other_financing_sources',
        transfers_usd                AS 'transfers'
    ))
    WHERE total_revenues_usd > 0              -- year filed
),

ia AS (
    SELECT
        *,
        SUM(COALESCE(actual_usd, 0)) OVER (PARTITION BY city_code, fiscal_year) AS city_year_actual
    FROM {{ ref('stg_us_ia_city_revenues') }}
),

fl AS (
    -- Revenue codes are three digits with several named lines under one
    -- code (312: three separate fuel taxes; 331: one federal grant per
    -- purpose), unlike expenditures: the line is code + name.
    SELECT
        municipality_file,
        ANY_VALUE(municipality)                                             AS municipality,
        fiscal_year,
        account_code,
        account_name,
        SUM(IFNULL(general_usd, 0) + IFNULL(special_revenue_usd, 0) + IFNULL(debt_service_usd, 0)
          + IFNULL(capital_projects_usd, 0) + IFNULL(permanent_usd, 0) + IFNULL(enterprise_usd, 0)
          + IFNULL(component_units_usd, 0))                                 AS own_funds_usd
    FROM {{ ref('stg_us_fl_municipal_revenues') }}
    WHERE level = 'account'                   -- group rows are subtotals of these
    GROUP BY 1, 3, 4, 5
),

ca AS (
    SELECT
        city_name,
        fiscal_year,
        category,
        subcategory_1,
        form_table,
        IF(category LIKE '%Enterprise Fund' AND STARTS_WITH(subcategory_1, 'Nonoperating'),
           'ENTERPRISE_NONOPERATING',
           CONCAT(category, '|', COALESCE(subcategory_1, ''), '|', COALESCE(ANY_VALUE(subcategory_2), ''))) AS map_key,
        -- the SCO suffixes every line with its section ("Sales and Use
        -- Taxes_General Revenues"); an enterprise fund reads best by its name
        IF(category LIKE '%Enterprise Fund',
           category,
           TRIM(REGEXP_REPLACE(COALESCE(ANY_VALUE(subcategory_3), ANY_VALUE(subcategory_2), subcategory_1), r'_.*$', ''))) AS label,
        SUM(amount_usd)                                                     AS amount_usd
    FROM {{ ref('stg_us_ca_city_revenues') }}
    WHERE amount_usd IS NOT NULL AND amount_usd != 0
    GROUP BY 1, 2, 3, 4, 5
),

lines AS (
    SELECT 'MA' AS state, 'ma_schedule_a_rev' AS source_system, dor_code AS government_key,
           municipality AS government_name, fiscal_year,
           'actual' AS document, 'general_fund' AS fund_scope,
           col AS source_key, col AS map_key,
           CASE col
               WHEN 'taxes'                   THEN 'Property tax and local excises'
               WHEN 'federal_revenue'         THEN 'From the federal government'
               WHEN 'state_revenue'           THEN 'From the state'
               WHEN 'other_governments'       THEN 'From other governments'
               WHEN 'service_charges'         THEN 'Charges for services'
               WHEN 'special_assessments'     THEN 'Special assessments'
               WHEN 'licenses_and_permits'    THEN 'Licenses and permits'
               WHEN 'fines_and_forfeitures'   THEN 'Fines and forfeitures'
               WHEN 'miscellaneous'           THEN 'Other revenue'
               WHEN 'other_financing_sources' THEN 'Bonds and other financing'
               WHEN 'transfers'               THEN 'Transfers from other funds'
           END AS source_label,
           CAST(NULL AS STRING) AS detail,
           amount AS amount_usd
    FROM ma

    UNION ALL
    SELECT 'IA', 'ia_dom_revenue', city_code, city_name, fiscal_year,
           'voted_budget', 'all_funds', revenue_type, revenue_type, revenue_type, NULL, budget_usd
    FROM ia

    UNION ALL
    SELECT 'IA', 'ia_dom_revenue', city_code, city_name, fiscal_year,
           'actual', 'all_funds', revenue_type, revenue_type, revenue_type, NULL, actual_usd
    FROM ia
    WHERE city_year_actual > 0                -- filed

    UNION ALL
    SELECT 'FL', 'fl_uas_revenue', municipality_file, municipality, fiscal_year,
           'actual', 'all_funds', CONCAT(account_code, '|', COALESCE(account_name, '')), account_code,
           -- "Physical Environment - Electric Utility": the function group in front
           -- of a charge adds nothing under its category; other prefixes carry
           -- the meaning ("Utility Service Tax - Electricity") and stay
           REGEXP_REPLACE(account_name,
               r'^(General Government|Public Safety|Physical Environment|Transportation|Economic Environment|Human Services|Culture / Recreation|Proprietary Non-Operating Sources|State Shared Revenues - [^-]+) - ',
               ''), NULL, own_funds_usd
    FROM fl
    WHERE own_funds_usd != 0

    UNION ALL
    SELECT 'CA', 'ca_sco_revenue', city_name, city_name, fiscal_year,
           'actual', 'all_funds', CONCAT(category, '|', COALESCE(subcategory_1, ''), '|', form_table),
           map_key, label, NULL, amount_usd
    FROM ca
)

SELECT
    TO_HEX(MD5(CONCAT(source_system, '|', government_key, '|', CAST(fiscal_year AS STRING), '|',
                      document, '|', source_key, '|', COALESCE(detail, '')))) AS line_id,
    *
FROM lines
WHERE amount_usd IS NOT NULL
