-- =============================================================================
-- Staging: Iowa city budget and actual revenues, FY2007+
--
-- Source: raw.us_ia_city_budget_actual_revenues (data.iowa.gov dataset 928)
-- Grain:  one row per (fiscal_year, city_code, revenue_type)
-- =============================================================================

SELECT
    {{ us_lf_int('fiscal_year') }}                      AS fiscal_year,
    SAFE_CAST(fiscal_year_end_date AS DATE)             AS fiscal_year_end_date,
    {{ us_lf_string('city_code') }}                     AS city_code,
    {{ us_lf_string('city_name') }}                     AS city_name,
    {{ us_lf_string('county_code') }}                   AS county_code,
    {{ us_lf_string('county') }}                        AS county_name,
    {{ us_lf_string('gnis_feature_id') }}               AS gnis_feature_id,
    {{ us_lf_string('revenue_type') }}                  AS revenue_type,
    {{ us_lf_amount('budget') }}                        AS budget_usd,
    {{ us_lf_amount('actual') }}                        AS actual_usd,
    _source                                             AS source,
    _source_url                                         AS source_url,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_ia_city_budget_actual_revenues') }}
