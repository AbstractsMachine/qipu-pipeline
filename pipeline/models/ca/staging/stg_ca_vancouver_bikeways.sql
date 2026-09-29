-- =============================================================================
-- Staging: bikeway segments with facility type, status and construction year.
--
-- Source: raw.ca_vancouver_bikeways (ODS). `geom` is the ODS GeoJSON Feature serialised to a JSON
-- string by the adapter → `$.geometry` → GEOGRAPHY (make_valid). Map input
-- (ADR-0012): the city-map encoder reads these back through core/marts.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    NULLIF(TRIM(object_id), '')                         AS bikeway_id,
    NULLIF(TRIM(bike_route_name), '')                   AS route_name,
    NULLIF(TRIM(street_name), '')                       AS street_name,
    NULLIF(TRIM(bikeway_type), '')                      AS bikeway_type,
    NULLIF(TRIM(subtype), '')                           AS subtype,
    NULLIF(TRIM(status), '')                            AS status,
    NULLIF(TRIM(surface_type), '')                      AS surface_type,
    CASE WHEN SAFE_CAST(REGEXP_EXTRACT(year_of_construction, r'(\d{4})') AS INT64) BETWEEN 1900 AND 2100
         THEN SAFE_CAST(REGEXP_EXTRACT(year_of_construction, r'(\d{4})') AS INT64) END AS year_of_construction,
    CASE WHEN SAFE_CAST(REGEXP_EXTRACT(upgrade_year, r'(\d{4})') AS INT64) BETWEEN 1900 AND 2100
         THEN SAFE_CAST(REGEXP_EXTRACT(upgrade_year, r'(\d{4})') AS INT64) END AS upgrade_year,
    SAFE.ST_GEOGFROMGEOJSON(JSON_QUERY(SAFE_CAST(geom AS STRING), '$.geometry'), make_valid => TRUE) AS geog,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_bikeways') }}
