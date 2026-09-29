-- =============================================================================
-- Staging: city block outlines, one row per block polygon.
--
-- Source: raw.ca_vancouver_block_outlines (ODS). `geom` is the ODS GeoJSON Feature serialised to a JSON
-- string by the adapter → `$.geometry` → GEOGRAPHY (make_valid). Map input
-- (ADR-0012): the city-map encoder reads these back through core/marts.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    SAFE.ST_GEOGFROMGEOJSON(JSON_QUERY(SAFE_CAST(geom AS STRING), '$.geometry'), make_valid => TRUE) AS geog,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_block_outlines') }}
