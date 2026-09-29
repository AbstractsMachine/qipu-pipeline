-- =============================================================================
-- Staging: Census Individual Unit File — unit directory (Fin_PID), 2017+
--
-- Source: raw.us_census_iuf_units
-- Grain:  one row per (file_year, unit_id)
-- =============================================================================

SELECT
    unit_id,
    {{ us_lf_int('file_year') }}                        AS file_year,
    SUBSTR(unit_id, 1, 2)                               AS state_fips,
    SUBSTR(unit_id, 3, 1)                               AS gov_type_code,
    CASE SUBSTR(unit_id, 3, 1)
        WHEN '0' THEN 'state'
        WHEN '1' THEN 'county'
        WHEN '2' THEN 'municipality'
        WHEN '3' THEN 'township'
        WHEN '4' THEN 'special_district'
        WHEN '5' THEN 'school_district'
    END                                                 AS gov_type,
    {{ us_lf_string('name') }}                          AS unit_name,
    {{ us_lf_string('county_name') }}                   AS county_name,
    {{ us_lf_string('fips_place') }}                    AS fips_place,
    {{ us_lf_int('population') }}                       AS population,
    {{ us_lf_string('population_year') }}               AS population_year,
    {{ us_lf_int('enrollment') }}                       AS enrollment,
    {{ us_lf_string('special_district_function') }}     AS special_district_function,
    {{ us_lf_string('fiscal_year_ending') }}            AS fiscal_year_ending_mmdd,
    _source                                             AS source,
    _source_url                                         AS source_url,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_census_iuf_units') }}
