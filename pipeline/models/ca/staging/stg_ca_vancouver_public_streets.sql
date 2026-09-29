-- =============================================================================
-- Staging: street centrelines; `hblock` is the hundred-block label ('2300 W 47TH AV').
--
-- Source: raw.ca_vancouver_public_streets (ODS). `geom` is the ODS GeoJSON Feature serialised to a JSON
-- string by the adapter → `$.geometry` → GEOGRAPHY (make_valid). Map input
-- (ADR-0012): the city-map encoder reads these back through core/marts.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    NULLIF(TRIM(hblock), '')                            AS hblock,
    -- the street name is the hundred-block label minus its leading block
    -- range ('6500-6600 BALSAM ST' → 'BALSAM ST')
    NULLIF(TRIM(REGEXP_REPLACE(hblock, r'^[0-9]+(?:-[0-9]+)?\s+', '')), '') AS street_name,
    NULLIF(TRIM(streetuse), '')                         AS street_use,
    SAFE.ST_GEOGFROMGEOJSON(JSON_QUERY(SAFE_CAST(geom AS STRING), '$.geometry'), make_valid => TRUE) AS geog,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_public_streets') }}
