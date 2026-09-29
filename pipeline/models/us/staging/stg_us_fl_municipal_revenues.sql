-- =============================================================================
-- Staging: Florida municipal revenues by Uniform Accounting System account
-- code and fund type (actuals, from DFS Annual Financial Reports via EDR)
--
-- Source: raw.us_fl_edr_municipal_revenues (one workbook per municipality,
--         one sheet per fiscal year, ~5 recent years)
-- Grain:  one row per (municipality_file, fiscal_year, level, account)
--         level = 'group'   → function subtotal (e.g. General Government Services)
--         level = 'account' → UAS account code (e.g. 511 Legislative)
-- Fund columns vary by year (no Custodial before GASB 84): missing = NULL.
-- =============================================================================

SELECT
    {{ us_lf_string('municipality_file') }}             AS municipality_file,
    REGEXP_EXTRACT(title, r'^(.*?) (?:Expenditures|Revenues) Reported')
                                                        AS municipality,
    {{ us_lf_int('fiscal_year') }}                      AS fiscal_year,
    {{ us_lf_string('level') }}                         AS level,
    {{ us_lf_string('group_name') }}                    AS group_name,
    {{ us_lf_string('account_code') }}                  AS account_code,
    {{ us_lf_string('account_name') }}                  AS account_name,
    {{ us_lf_amount('general') }}                       AS general_usd,
    {{ us_lf_amount('special_revenue') }}               AS special_revenue_usd,
    {{ us_lf_amount('debt_service') }}                  AS debt_service_usd,
    {{ us_lf_amount('capital_projects') }}              AS capital_projects_usd,
    {{ us_lf_amount('permanent') }}                     AS permanent_usd,
    {{ us_lf_amount('enterprise') }}                    AS enterprise_usd,
    {{ us_lf_amount('internal_service') }}              AS internal_service_usd,
    {{ us_lf_amount('custodial') }}                     AS custodial_usd,
    {{ us_lf_amount('agency') }}                        AS agency_usd,
    {{ us_lf_amount('pension') }}                       AS pension_usd,
    {{ us_lf_amount('trust') }}                         AS trust_usd,
    {{ us_lf_amount('private_purpose') }}               AS private_purpose_usd,
    {{ us_lf_amount('component_units') }}               AS component_units_usd,
    {{ us_lf_amount('total_account') }}                 AS total_account_usd,
    {{ us_lf_amount('per_capita_account') }}            AS per_capita_account_usd,
    _source                                             AS source,
    _source_url                                         AS source_url,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_fl_edr_municipal_revenues') }}
