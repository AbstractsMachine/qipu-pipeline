-- =============================================================================
-- Staging: Indiana cities' and towns' debt, one row per issue per year
--
-- Source: raw.us_in_afr_debt (SBOA Gateway, Annual Financial Report, Debt)
-- Grain:  unit × fiscal year × issue (bond, loan, note, lease) — the balance
--         owed at the end of the year and the principal due within a year.
-- All the unit's funds: governmental and its utilities (water, sewer,
-- electric revenue bonds). Paid-off issues stay listed at a zero balance.
-- =============================================================================

SELECT
    {{ us_lf_string('county_cd_fk') }}                  AS county_code,
    {{ us_lf_string('unit_code') }}                     AS unit_code,
    {{ us_lf_string('unit_name') }}                     AS unit_name,
    {{ us_lf_int('year') }}                             AS fiscal_year,
    {{ us_lf_string('ent_name') }}                      AS fund_name,
    {{ us_lf_string('debt_class_name') }}               AS debt_class,
    {{ us_lf_string('debt_description') }}              AS description,
    {{ us_lf_amount('end_principal_bal') }}             AS outstanding_usd,
    {{ us_lf_amount('principal_amt_due_1yr') }}         AS due_within_year_usd,
    _source                                             AS source,
    _source_url                                         AS source_url,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_in_afr_debt') }}
