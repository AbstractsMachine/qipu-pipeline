-- Iowa city property tax rates ($ per $1,000 of taxable value) from the DOM
-- yearly files: the TOTAL rate and the DEBT SERVICE levy, read by header.
SELECT
    {{ us_lf_string('city_code') }}                     AS city_code,
    {{ us_lf_string('city_name') }}                     AS city_name,
    {{ us_lf_int('fiscal_year') }}                      AS fiscal_year,
    {{ us_lf_amount('total_rate') }}                    AS total_rate,
    {{ us_lf_string('total_rate_basis') }}              AS total_rate_basis,
    {{ us_lf_amount('debt_service_rate') }}             AS debt_service_rate,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_ia_dom_city_tax_rates') }}
