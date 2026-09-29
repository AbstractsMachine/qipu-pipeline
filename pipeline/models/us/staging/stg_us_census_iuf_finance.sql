-- =============================================================================
-- Staging: Census Individual Unit File — finance records, 2017+
--
-- Source: raw.us_census_iuf_finance (fixed-width file split by the sync, all strings)
-- Grain:  one row per (file_year, unit_id, item_code)
--
-- amount_usd is converted from THOUSANDS. unit_id = FIPS state(2) + type(1)
-- + FIPS county(3) + unit(6). Census years (2017, 2022) cover every local
-- government; other years are a sample. 2022 is inflated by ARPA money.
-- =============================================================================

SELECT
    unit_id,
    SUBSTR(unit_id, 1, 2)                               AS state_fips,
    SUBSTR(unit_id, 3, 1)                               AS gov_type_code,
    item_code,
    {{ us_lf_census_amount('amount_thousands') }}       AS amount_usd,
    {{ us_lf_int('data_year') }}                        AS data_year,
    {{ us_lf_int('file_year') }}                        AS file_year,
    {{ us_lf_string('imputation_flag') }}               AS imputation_flag,
    _source                                             AS source,
    _source_url                                         AS source_url,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_census_iuf_finance') }}
