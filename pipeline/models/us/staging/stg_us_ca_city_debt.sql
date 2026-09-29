-- California cities' long-term debt per issue (SCO Cities Raw Data): bonds
-- and COPs (sheet 31) and other long-term debt (sheet 32) in one shape.
SELECT
    {{ us_lf_string('entity_name') }}                   AS city_name,
    {{ us_lf_int('fiscal_year') }}                      AS fiscal_year,
    'bonds'                                             AS sheet,
    {{ us_lf_string('purpose_of_debt') }}               AS purpose,
    {{ us_lf_string('debt_type') }}                     AS debt_type,
    {{ us_lf_string('fund_type') }}                     AS fund_type,
    {{ us_lf_amount('principal_payable_end_of_fiscal_year') }} AS outstanding_usd,
    {{ us_lf_amount('principal_payable_current_portion') }}    AS due_within_year_usd,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_ca_sco_city_lt_debt') }}
UNION ALL
SELECT
    {{ us_lf_string('entity_name') }},
    {{ us_lf_int('fiscal_year') }},
    'other',
    {{ us_lf_string('purpose_of_debt') }},
    {{ us_lf_string('debt_type') }},
    {{ us_lf_string('fund_type') }},
    {{ us_lf_amount('principal_outstanding_end_of_fiscal_year') }},
    {{ us_lf_amount('principal_outstanding_current_portion') }},
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_ca_sco_city_other_lt_debt') }}
