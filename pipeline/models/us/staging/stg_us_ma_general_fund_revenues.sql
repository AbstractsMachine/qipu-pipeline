-- =============================================================================
-- Staging: Massachusetts Schedule A general fund revenues by source, FY2002+
--
-- Source: raw.us_ma_dls_general_fund_revenues (DLS ScheduleA.GeneralFund, Revenues)
-- Grain:  one row per (dor_code, fiscal_year); sources kept wide as published.
-- The "Totals:" row (statewide sum, no year) is dropped, as for expenditures.
-- =============================================================================

SELECT
    {{ us_lf_string('dor_code') }}                          AS dor_code,
    {{ us_lf_string('municipality') }}                      AS municipality,
    {{ us_lf_int('fiscal_year') }}                          AS fiscal_year,
    {{ us_lf_amount('taxes') }}                             AS taxes_usd,
    {{ us_lf_amount('service_charges') }}                   AS service_charges_usd,
    {{ us_lf_amount('licenses_and_permits') }}              AS licenses_and_permits_usd,
    {{ us_lf_amount('federal_revenue') }}                   AS federal_revenue_usd,
    {{ us_lf_amount('state_revenue') }}                     AS state_revenue_usd,
    {{ us_lf_amount('revenue_from_other_governments') }}    AS other_governments_usd,
    {{ us_lf_amount('special_assessments') }}               AS special_assessments_usd,
    {{ us_lf_amount('fines_and_forfeitures') }}             AS fines_and_forfeitures_usd,
    {{ us_lf_amount('miscellaneous') }}                     AS miscellaneous_usd,
    {{ us_lf_amount('other_financing_sources') }}           AS other_financing_sources_usd,
    {{ us_lf_amount('transfers') }}                         AS transfers_usd,
    {{ us_lf_amount('total_revenues') }}                    AS total_revenues_usd,
    _source                                                 AS source,
    _source_url                                             AS source_url,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_ma_dls_general_fund_revenues') }}
WHERE REGEXP_CONTAINS(dor_code, r'^\d{3}$')
