-- =============================================================================
-- Staging: Iowa city budget and actual expenditures, FY2007+
--
-- Source: raw.us_ia_city_budget_actual_expenditures (data.iowa.gov dataset 925)
-- Grain:  one row per (fiscal_year, city_code, function)
--
-- budget_usd and actual_usd share the row: one nomenclature for both
-- documents. Actuals lag ~2 fiscal years and arrive as 0 until filed — the
-- zero is NOT a spending figure; core decides which years carry actuals.
--
-- DUPLICATES IN THE SOURCE: FY2018 is published twice — 8,661 (year, city,
-- function) groups, same record_id, identical values (measured 2026-09-22).
-- Summed as-is, every Iowa city's 2018 spending would read double. One row per
-- record_id is kept; the grain test in schema_local_finance.yml guards it.
-- =============================================================================

SELECT
    {{ us_lf_int('fiscal_year') }}                      AS fiscal_year,
    SAFE_CAST(fiscal_year_end_date AS DATE)             AS fiscal_year_end_date,
    {{ us_lf_string('city_code') }}                     AS city_code,
    {{ us_lf_string('city_name') }}                     AS city_name,
    {{ us_lf_string('county_code') }}                   AS county_code,
    {{ us_lf_string('county_name') }}                   AS county_name,
    {{ us_lf_string('gnis_feature_id') }}               AS gnis_feature_id,
    {{ us_lf_string('`function`') }}                    AS function_name,
    {{ us_lf_amount('budget') }}                        AS budget_usd,
    {{ us_lf_amount('actual') }}                        AS actual_usd,
    _source                                             AS source,
    _source_url                                         AS source_url,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_ia_city_budget_actual_expenditures') }}
WHERE TRUE
QUALIFY ROW_NUMBER() OVER (PARTITION BY record_id ORDER BY _synced_at) = 1
