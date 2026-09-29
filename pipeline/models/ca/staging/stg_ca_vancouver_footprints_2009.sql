-- =============================================================================
-- Staging: building footprints 2009 with the City's own LiDAR statistics.
--
-- Source: raw.ca_vancouver_building_footprints_2009 (ODS building-footprints-2009).
-- Heights in metres above ground (hgt_agl), plus min/avg/max, base and top
-- elevations and a roof type. Kept as the City's own measurement to check the
-- 2016 HRDEM re-measurement against (see core_ca_vancouver_buildings).
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    SAFE_CAST(id AS INT64)                               AS footprint_2009_id,
    SAFE_CAST(bldgid AS INT64)                           AS bldg_id,
    SAFE_CAST(hgt_agl AS FLOAT64)                        AS height_agl_m,
    SAFE_CAST(avght_m AS FLOAT64)                        AS height_avg_m,
    SAFE_CAST(minht_m AS FLOAT64)                        AS height_min_m,
    SAFE_CAST(maxht_m AS FLOAT64)                        AS height_max_m,
    SAFE_CAST(baseelev_m AS FLOAT64)                     AS base_elev_m,
    SAFE_CAST(topelev_m AS FLOAT64)                      AS top_elev_m,
    NULLIF(TRIM(rooftype), '')                           AS roof_type,
    SAFE_CAST(med_slope AS INT64)                        AS roof_median_slope_deg,
    SAFE_CAST(orient8 AS FLOAT64)                        AS orientation_rad,
    SAFE_CAST(area_m2 AS FLOAT64)                        AS area_m2,
    SAFE.ST_GEOGFROMGEOJSON(JSON_QUERY(SAFE_CAST(geom AS STRING), '$.geometry'), make_valid => TRUE) AS geog,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_building_footprints_2009') }}
