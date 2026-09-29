-- =============================================================================
-- Staging: building footprints 2015 — outlines traced from the City's 2015
-- orthophotos, one row per outline. No height (heights: LiDAR, below).
--
-- Source: raw.ca_vancouver_building_footprints_2015 (ODS building-footprints-2015).
-- Contiguous outlines are split at parcel lines by the City, so a row is a
-- building PER OWNERSHIP, which is the unit the assessment roll dates.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    SAFE_CAST(object_id AS INT64)                        AS footprint_id,
    SAFE.ST_GEOGFROMGEOJSON(JSON_QUERY(SAFE_CAST(geom AS STRING), '$.geometry'), make_valid => TRUE) AS geog,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_building_footprints_2015') }}
