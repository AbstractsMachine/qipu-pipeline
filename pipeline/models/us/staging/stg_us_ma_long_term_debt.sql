-- Massachusetts long-term debt per municipality (DLS, Schedule A Parts 2 and 10).
SELECT
    {{ us_lf_string('dor_code') }}                      AS dor_code,
    {{ us_lf_string('municipality') }}                  AS municipality,
    {{ us_lf_int('fiscal_year') }}                      AS fiscal_year,
    {{ us_lf_amount('total_outstanding_debt_schedule_a_part_10') }} AS outstanding_usd,
    {{ us_lf_amount('gf_debt_service_schedule_a_part_2') }}         AS gf_debt_service_usd,
    {{ us_lf_amount('total_budget') }}                  AS total_budget_usd,
    {{ us_lf_int('population') }}                       AS population,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_ma_dls_long_term_debt') }}
WHERE REGEXP_CONTAINS(dor_code, r'^\d{3}$') AND total_outstanding_debt_schedule_a_part_10 IS NOT NULL
