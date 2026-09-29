-- =============================================================================
-- Staging: railway track alignments by operator.
--
-- Source: raw.ca_vancouver_railways (ODS). `geom` is the ODS GeoJSON Feature serialised to a JSON
-- string by the adapter → `$.geometry` → GEOGRAPHY (make_valid). Map input
-- (ADR-0012): the city-map encoder reads these back through core/marts.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    NULLIF(TRIM(name), '')                              AS operator_name,
    SAFE.ST_GEOGFROMGEOJSON(JSON_QUERY(SAFE_CAST(geom AS STRING), '$.geometry'), make_valid => TRUE) AS geog,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_railways') }}
