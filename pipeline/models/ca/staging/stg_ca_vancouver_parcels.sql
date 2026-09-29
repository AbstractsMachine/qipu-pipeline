-- =============================================================================
-- Staging: parcel polygons — typed, geometry parsed, one row per parcel.
--
-- Source: raw.ca_vancouver_property_parcel_polygons (ODS property-parcel-polygons).
-- `geom` is the ODS GeoJSON Feature serialised to a JSON string by the
-- adapter → `$.geometry` → GEOGRAPHY. `geo_point_2d` is {lon,lat} → POINT.
-- tax_coord is the join key to the assessment roll (land_coordinate), 1:1.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

SELECT
    NULLIF(TRIM(SAFE_CAST(tax_coord AS STRING)), '')     AS tax_coord,
    NULLIF(TRIM(SAFE_CAST(site_id AS STRING)), '')       AS site_id,
    NULLIF(TRIM(SAFE_CAST(civic_number AS STRING)), '')  AS civic_number,
    NULLIF(TRIM(SAFE_CAST(streetname AS STRING)), '')    AS street_name,
    SAFE.ST_GEOGFROMGEOJSON(JSON_QUERY(SAFE_CAST(geom AS STRING), '$.geometry'), make_valid => TRUE) AS parcel_geog,
    SAFE_CAST(JSON_VALUE(SAFE_CAST(geo_point_2d AS STRING), '$.lon') AS FLOAT64) AS lon,
    SAFE_CAST(JSON_VALUE(SAFE_CAST(geo_point_2d AS STRING), '$.lat') AS FLOAT64) AS lat,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_property_parcel_polygons') }}
