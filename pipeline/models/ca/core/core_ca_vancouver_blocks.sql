-- =============================================================================
-- Core: city blocks — one row per published block outline, the map's massing
-- unit and its pick target.
--
-- block_idx is deterministic (ordered by centroid, then WKT), because the
-- chunk format joins every per-block column POSITIONALLY. area_idx is the
-- local area containing the block's centroid; a block whose centroid falls
-- in no local area (the handful west of the city limit that the outline layer
-- carries) gets NULL and the encoder decides whether to draw it.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core', 'citymap']) }}

WITH b AS (
    SELECT geog, ST_CENTROID(geog) AS c, _synced_at
    FROM {{ ref('stg_ca_vancouver_block_outlines') }}
    WHERE geog IS NOT NULL AND ST_DIMENSION(geog) = 2
)

SELECT
    ROW_NUMBER() OVER (ORDER BY ST_Y(b.c), ST_X(b.c), ST_ASTEXT(b.geog)) - 1 AS block_idx,
    b.geog,
    ST_X(b.c)            AS lon,
    ST_Y(b.c)            AS lat,
    ST_AREA(b.geog)      AS area_m2,
    a.area_idx,
    a.local_area,
    b._synced_at
FROM b
LEFT JOIN {{ ref('core_ca_vancouver_local_areas') }} a
  ON ST_CONTAINS(a.geog, b.c)
