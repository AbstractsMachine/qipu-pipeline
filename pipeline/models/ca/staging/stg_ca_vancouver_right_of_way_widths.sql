-- =============================================================================
-- Staging: legal right-of-way widths (property line to property line), one
-- labelled point per street span.
--
-- UNITS ARE NOT PUBLISHED, and the values mix two systems: '20' (11,077
-- rows) and '66' (5,758) are the two commonest labels, and 66 is the classic
-- one-chain road allowance in FEET (= 20.1 m) while 20 reads as metres.
-- Measured 2026-09-13. So the number is kept as published and NO metric
-- width is derived here; the map does not draw street widths from this
-- source until the unit can be established per row.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    NULLIF(TRIM(width), '')                                  AS width_label,
    SAFE_CAST(REGEXP_EXTRACT(width, r'([0-9]+(?:\.[0-9]+)?)') AS FLOAT64) AS width_value_unitless,
    SAFE.ST_GEOGFROMGEOJSON(JSON_QUERY(SAFE_CAST(geom AS STRING), '$.geometry'), make_valid => TRUE) AS geog,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_right_of_way_widths') }}
