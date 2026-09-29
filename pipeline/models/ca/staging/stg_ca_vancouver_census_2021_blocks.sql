-- =============================================================================
-- Staging: 2021 Census dissemination blocks of the City of Vancouver.
--
-- Source: raw.ca_vancouver_census_2021_blocks, written by
-- pipeline/scripts/ca_vancouver_city/fetch_census_blocks.py from Statistics
-- Canada's Geographic Attribute File (counts) and cartographic boundary file
-- (outlines, clipped to the shoreline). One row per block as published; a block
-- the boundary service returned no outline for keeps a NULL geog.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    dbuid,
    dauid,
    ctuid,
    SAFE_CAST(population AS INT64)                  AS population,
    SAFE_CAST(dwellings AS INT64)                   AS dwellings,
    SAFE_CAST(dwellings_usual_residents AS INT64)   AS dwellings_usual_residents,
    SAFE_CAST(land_area_km2 AS FLOAT64)             AS land_area_km2,
    SAFE.ST_GEOGFROMGEOJSON(geog_geojson, make_valid => TRUE) AS geog,
    source_url,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_census_2021_blocks') }}
