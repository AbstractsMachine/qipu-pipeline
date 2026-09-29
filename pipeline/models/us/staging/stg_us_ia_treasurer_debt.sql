-- Iowa Treasurer's outstanding obligations at June 30: cities only.
SELECT
    {{ us_lf_string('name') }}                          AS city_name,
    {{ us_lf_int('fiscal_year') }}                      AS fiscal_year,
    {{ us_lf_amount('total_outstanding') }}             AS outstanding_usd,
    {{ us_lf_int('population') }}                       AS population,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_ia_treasurer_debt') }}
WHERE section = 'Cities'
