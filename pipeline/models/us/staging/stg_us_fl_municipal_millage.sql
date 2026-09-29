-- Florida DOR Municipal Report: the city millage rate ($ per $1,000 of
-- taxable value) and taxes levied, per municipality and year. The file's
-- "Pct Change" rows (no year) are its own ratios: dropped.
SELECT
    {{ us_lf_string('municipality') }}                  AS municipality,
    {{ us_lf_string('sheet') }}                         AS county,
    {{ us_lf_int('year') }}                             AS tax_year,
    {{ us_lf_amount('city_millage_rate') }}             AS millage,
    {{ us_lf_amount('taxes_levied') }}                  AS taxes_levied_usd,
    {{ us_lf_amount('total_taxable_value') }}           AS taxable_value_usd,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_fl_dor_municipal_millage') }}
WHERE SAFE_CAST(year AS INT64) IS NOT NULL AND municipality IS NOT NULL
