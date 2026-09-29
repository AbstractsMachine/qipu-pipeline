-- =============================================================================
-- Staging: LiDAR height distribution per 2015 footprint (measured source).
--
-- Source: raw.ca_vancouver_building_heights_lidar, written by
-- pipeline/scripts/ca_vancouver_city/measure_building_heights.py from NRCan
-- HRDEM `BC-Lower_Mainland_2016-1m` (DSM − DTM, 1 m). One row per footprint
-- that had at least one pixel. Provenance columns travel with every row.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    SAFE_CAST(object_id AS INT64)    AS footprint_id,
    SAFE_CAST(n_px AS INT64)         AS n_px,
    SAFE_CAST(h_p50 AS FLOAT64)      AS h_p50_m,
    SAFE_CAST(h_p90 AS FLOAT64)      AS h_p90_m,
    SAFE_CAST(h_p25 AS FLOAT64)      AS h_p25_m,
    SAFE_CAST(h_p75 AS FLOAT64)      AS h_p75_m,
    SAFE_CAST(h_p95 AS FLOAT64)      AS h_p95_m,
    SAFE_CAST(share_upper AS FLOAT64) AS share_upper,
    SAFE_CAST(h_max AS FLOAT64)      AS h_max_m,
    SAFE_CAST(h_mean AS FLOAT64)     AS h_mean_m,
    SAFE_CAST(ground_p50 AS FLOAT64) AS ground_m,
    survey_id, dsm_url, dtm_url, source_url, license,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_building_heights_lidar') }}
