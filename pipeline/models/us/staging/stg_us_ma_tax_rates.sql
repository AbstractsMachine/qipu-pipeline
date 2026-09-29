-- Massachusetts tax rates by class, $ per $1,000 of assessed value (DLS).
-- A year not yet certified carries zeros: kept out (rate > 0).
SELECT
    {{ us_lf_string('dor_code') }}                      AS dor_code,
    {{ us_lf_string('municipality') }}                  AS municipality,
    {{ us_lf_int('fiscal_year') }}                      AS fiscal_year,
    {{ us_lf_amount('residential') }}                   AS residential_rate,
    {{ us_lf_amount('open_space') }}                    AS open_space_rate,
    {{ us_lf_amount('commercial') }}                    AS commercial_rate,
    {{ us_lf_amount('industrial') }}                    AS industrial_rate,
    {{ us_lf_amount('personal_property') }}             AS personal_property_rate,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_ma_dls_tax_rates') }}
WHERE REGEXP_CONTAINS(dor_code, r'^\d{3}$') AND SAFE_CAST(residential AS FLOAT64) > 0
