-- Indiana DLGF certified budget, levy and tax rate (per $100 of assessed
-- value) per unit × fund, by the year the tax is paid. The 2022 file names
-- its columns "2022 Certified …": both spellings read.
SELECT
    {{ us_lf_string('county') }}                        AS county_code,
    {{ us_lf_string('unit_type_code') }}                AS unit_type_code,
    {{ us_lf_string('unit_code') }}                     AS unit_code,
    {{ us_lf_string('unit_name') }}                     AS unit_name,
    {{ us_lf_string('fund') }}                          AS fund_code,
    {{ us_lf_string('fund_name') }}                     AS fund_name,
    {{ us_lf_int('file_year') }}                        AS pay_year,
    COALESCE({{ us_lf_amount('certified_levy') }}, {{ us_lf_amount('c_2022_certified_levy') }})               AS levy_usd,
    COALESCE({{ us_lf_amount('certified_gross_tax_rate') }}, {{ us_lf_amount('c_2022_certified_gross_tax_rate') }}) AS rate_per_100,
    COALESCE({{ us_lf_amount('certified_net_assessed_valuation') }}, {{ us_lf_amount('c_2022_certified_net_assessed_valuation') }}) AS net_assessed_value_usd,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_in_dlgf_certified_rates') }}
