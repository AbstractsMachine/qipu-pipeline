-- =============================================================================
-- Staging: Massachusetts Schedule A general fund expenditures by function,
-- FY2002+ (actuals)
--
-- Source: raw.us_ma_dls_general_fund_expenditures (DLS ScheduleA.GeneralFund)
-- Grain:  one row per (dor_code, fiscal_year); functions kept wide as
--         published, unpivoted in core. A year not yet filed arrives as all
--         zeros — core drops rows whose total is 0.
-- Employee benefits sit in fixed_costs, NOT inside each function.
-- The export carries one "Totals:" row per year (statewide sum, no year):
-- kept, it would double every statewide figure — only 3-digit DOR codes pass.
-- =============================================================================

SELECT
    {{ us_lf_string('dor_code') }}                      AS dor_code,
    {{ us_lf_string('municipality') }}                  AS municipality,
    {{ us_lf_int('fiscal_year') }}                      AS fiscal_year,
    {{ us_lf_amount('general_government') }}           AS general_government_usd,
    {{ us_lf_amount('public_safety') }}                 AS public_safety_usd,
    {{ us_lf_amount('education') }}                     AS education_usd,
    {{ us_lf_amount('public_works') }}                  AS public_works_usd,
    {{ us_lf_amount('human_services') }}                AS human_services_usd,
    {{ us_lf_amount('culture_and_recreation') }}        AS culture_and_recreation_usd,
    {{ us_lf_amount('fixed_costs') }}                   AS fixed_costs_usd,
    {{ us_lf_amount('intergov_assessments') }}          AS intergov_assessments_usd,
    {{ us_lf_amount('other_expenditures') }}            AS other_expenditures_usd,
    {{ us_lf_amount('debt_service') }}                  AS debt_service_usd,
    {{ us_lf_amount('total_expenditures') }}            AS total_expenditures_usd,
    _source                                             AS source,
    _source_url                                         AS source_url,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_ma_dls_general_fund_expenditures') }}
WHERE REGEXP_CONTAINS(dor_code, r'^\d{3}$')
