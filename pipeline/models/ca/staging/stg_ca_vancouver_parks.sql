-- =============================================================================
-- Staging: park polygons with name and Park Board classification.
--
-- Source: raw.ca_vancouver_parks_polygons (ODS). `geom` is the ODS GeoJSON Feature serialised to a JSON
-- string by the adapter → `$.geometry` → GEOGRAPHY (make_valid). Map input
-- (ADR-0012): the city-map encoder reads these back through core/marts.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    SAFE_CAST(object_id AS INT64)                       AS park_object_id,
    NULLIF(TRIM(park_name), '')                         AS park_name,
    NULLIF(TRIM(park_url), '')                          AS park_url,
    NULLIF(TRIM(local_area), '')                        AS local_area,
    NULLIF(TRIM(classification), '')                    AS classification,
    SAFE_CAST(area_hectare AS FLOAT64)                  AS area_ha,
    SAFE.ST_GEOGFROMGEOJSON(JSON_QUERY(SAFE_CAST(geom AS STRING), '$.geometry'), make_valid => TRUE) AS geog,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_parks_polygons') }}
