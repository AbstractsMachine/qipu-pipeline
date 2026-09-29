-- =============================================================================
-- Core: BUILDINGS — one row per 2015 footprint, with its measured height, the
-- parcel it stands on, that parcel's build year, and the block / local area.
-- The map's fabric (ADR-0012 slots 6, 7, 8, 13).
--
--   height   : LiDAR, NRCan HRDEM BC-Lower_Mainland_2016-1m, DSM − DTM, the
--              MEDIAN over the footprint (stg_ca_vancouver_building_heights),
--              plus p90/p95 and share_upper so the encoder can draw a tower
--              on its podium as two levels rather than one median slab.
--              h_ok = the footprint had ≥ 4 pixels AND a positive median;
--              below that the measurement is noise and the encoder uses a
--              stated floor instead, flagged.
--   parcel   : the parcel polygon CONTAINING the footprint's centroid
--              (core_ca_vancouver_parcel_polygons → tax_coord); no nearest
--              fallback. A footprint on no parcel (a building on a road
--              allowance, a pier) keeps NULL.
--   year     : the parcel's oldest standing year_built in the 2025 roll
--              (core_ca_vancouver_parcels). SURVIVORSHIP: a year describes a
--              building still standing in 2025; one parcel's garage inherits
--              its house's year.
--   zone_cls : the ZONING DISTRICT family of that parcel folded to the
--              engine's seven classes. It is zoning — where the building
--              sits — not the building's use, which the roll does not publish.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core', 'citymap']) }}

WITH f AS (
    SELECT footprint_id, geog, ST_CENTROID(geog) AS c, ST_AREA(geog) AS area_m2, _synced_at
    FROM {{ ref('stg_ca_vancouver_footprints_2015') }}
    WHERE geog IS NOT NULL AND ST_DIMENSION(geog) = 2
),

on_parcel AS (
    SELECT f.footprint_id, ANY_VALUE(pp.tax_coord) AS tax_coord
    FROM f
    JOIN {{ ref('core_ca_vancouver_parcel_polygons') }} pp
      ON ST_CONTAINS(pp.parcel_geog, f.c)
    WHERE pp.tax_coord IS NOT NULL
    GROUP BY f.footprint_id
),

on_block AS (
    SELECT f.footprint_id, MIN(b.block_idx) AS block_idx
    FROM f
    JOIN {{ ref('core_ca_vancouver_blocks') }} b
      ON ST_CONTAINS(b.geog, f.c)
    GROUP BY f.footprint_id
),

in_area AS (
    SELECT f.footprint_id, MIN(a.area_idx) AS area_idx
    FROM f
    JOIN {{ ref('core_ca_vancouver_local_areas') }} a
      ON ST_CONTAINS(a.geog, f.c)
    GROUP BY f.footprint_id
)

SELECT
    f.footprint_id,
    f.geog,
    ST_X(f.c)                         AS lon,
    ST_Y(f.c)                         AS lat,
    f.area_m2,
    h.n_px,
    h.h_p50_m,
    h.h_p90_m,
    h.h_p95_m,
    h.share_upper,
    h.h_max_m,
    h.h_mean_m,
    h.ground_m,
    (h.n_px >= 4 AND h.h_p50_m > 0)   AS h_ok,
    h.survey_id                       AS height_survey_id,
    h.source_url                      AS height_source_url,
    h.license                         AS height_license,
    h.dsm_url                         AS height_dsm_url,
    h.dtm_url                         AS height_dtm_url,
    op.tax_coord,
    p.year_built,
    p.n_properties,
    p.zoning_district,
    p.zoning_classification,
    CASE
        WHEN p.zoning_district IS NULL                                   THEN 6
        WHEN REGEXP_CONTAINS(p.zoning_district, r'^(I|IC|M|MC-?I)\b|^(I|IC|M)-') THEN 4
        WHEN REGEXP_CONTAINS(p.zoning_district, r'^(C|MC|HA)-?')          THEN 2
        WHEN REGEXP_CONTAINS(p.zoning_district, r'^(DD|DEOD|FCCDD|BCPED|CWD)') THEN 3
        WHEN REGEXP_CONTAINS(p.zoning_district, r'^CD')                   THEN 6
        WHEN REGEXP_CONTAINS(p.zoning_district, r'^(RT|RM|FM|RR)')        THEN 1
        WHEN REGEXP_CONTAINS(p.zoning_district, r'^(R1|RS|R-|FSD|RA|R\b)') AND COALESCE(p.n_properties, 1) <= 2 THEN 0
        WHEN REGEXP_CONTAINS(p.zoning_district, r'^(R|FSD|RA)')           THEN 1
        ELSE 6
    END                               AS zone_cls,
    ob.block_idx,
    ia.area_idx,
    f._synced_at
FROM f
LEFT JOIN {{ ref('stg_ca_vancouver_building_heights') }} h USING (footprint_id)
LEFT JOIN on_parcel op USING (footprint_id)
LEFT JOIN {{ ref('core_ca_vancouver_parcels') }} p ON p.tax_coord = op.tax_coord
LEFT JOIN on_block ob USING (footprint_id)
LEFT JOIN in_area ia USING (footprint_id)
