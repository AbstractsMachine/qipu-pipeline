-- =============================================================================
-- Staging: Massachusetts voted operating budget (tax rate recap), FY2023+
--
-- Source: raw.us_ma_dls_operating_budget (DLS report 351BudgetperCapita)
-- Grain:  one row per (dor_code, fiscal_year). A TOTAL only: the recap files
--         appropriations by funding source, not by function.
-- =============================================================================

SELECT
    {{ us_lf_string('dor_code') }}                      AS dor_code,
    {{ us_lf_string('name') }}                          AS municipality,
    {{ us_lf_int('fiscal_year') }}                      AS fiscal_year,
    {{ us_lf_int('population') }}                       AS population,
    {{ us_lf_amount('operating_budget') }}              AS operating_budget_usd,
    {{ us_lf_amount('operating_budget_per_capita') }}   AS operating_budget_per_capita_usd,
    _source                                             AS source,
    _source_url                                         AS source_url,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_ma_dls_operating_budget') }}
WHERE REGEXP_CONTAINS(dor_code, r'^\d{3}$')      -- same guard as Schedule A (no totals row seen here)
