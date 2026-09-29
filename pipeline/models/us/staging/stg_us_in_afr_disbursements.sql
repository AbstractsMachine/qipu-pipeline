-- =============================================================================
-- Staging: Indiana Annual Financial Report — disbursements by fund and
-- department, cities and towns, 2016+ (actual spending)
--
-- Source: raw.us_in_afr_disbursements (Indiana Gateway, Annual Financial Reports)
-- Grain:  one row per (year, unit, fund, department, disbursement code)
-- =============================================================================

SELECT
    {{ us_lf_int('year') }}                             AS fiscal_year,
    {{ us_lf_string('cnty_cd') }}                       AS county_code,
    {{ us_lf_string('cnty_description') }}              AS county_name,
    {{ us_lf_string('budget_unit_type') }}              AS unit_type_code,
    {{ us_lf_string('unit_type_label') }}               AS unit_type,
    {{ us_lf_string('unit_code') }}                     AS unit_code,
    {{ us_lf_string('unit_name') }}                     AS unit_name,
    {{ us_lf_string('sboa_id') }}                       AS sboa_id,
    {{ us_lf_string('ent_name') }}                      AS entity_activity,
    {{ us_lf_string('fund_code') }}                     AS fund_code,
    {{ us_lf_string('unit_fund_name') }}                AS fund_name,
    {{ us_lf_string('department_code') }}               AS department_code,
    {{ us_lf_string('department_name') }}               AS department_name,
    {{ us_lf_string('disburse_code') }}                 AS disbursement_code,
    {{ us_lf_string('disburse_name') }}                 AS disbursement_name,
    {{ us_lf_string('disburse_class_code') }}           AS disbursement_class_code,
    {{ us_lf_string('disburse_class_name') }}           AS disbursement_class,
    {{ us_lf_amount('amount') }}                        AS amount_usd,
    _source                                             AS source,
    _source_url                                         AS source_url,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_in_afr_disbursements') }}
