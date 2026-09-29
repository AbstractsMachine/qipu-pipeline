-- =============================================================================
-- Core: 2021 Census dissemination blocks, each attributed to ONE city block.
--
-- The Census draws its own blocks (4,562 in the city) and they are not the
-- City's (4,624 in core_ca_vancouver_blocks). A census block is attributed to
-- the city block its outline overlaps MOST, by area (block_rule
-- 'largest_overlap'), and to nothing when it overlaps none — so nobody is
-- counted twice, and a city block that receives no census block carries no
-- population rather than a zero. `overlap_share` says how much of the census
-- block that city block holds.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core', 'citymap']) }}

WITH db AS (
    SELECT * FROM {{ ref('stg_ca_vancouver_census_2021_blocks') }}
),

overlap AS (
    SELECT
        db.dbuid,
        b.block_idx,
        ST_AREA(ST_INTERSECTION(db.geog, b.geog)) AS overlap_m2,
        ST_AREA(db.geog)                          AS db_area_m2
    FROM db
    JOIN {{ ref('core_ca_vancouver_blocks') }} b
      ON db.geog IS NOT NULL AND ST_INTERSECTS(db.geog, b.geog)
),

best AS (
    SELECT dbuid, block_idx, overlap_m2, db_area_m2
    FROM overlap
    WHERE overlap_m2 > 0
    QUALIFY ROW_NUMBER() OVER (PARTITION BY dbuid ORDER BY overlap_m2 DESC, block_idx) = 1
)

SELECT
    db.dbuid,
    db.dauid,
    db.ctuid,
    db.population,
    db.dwellings,
    db.dwellings_usual_residents,
    db.land_area_km2,
    best.block_idx,
    IF(best.block_idx IS NULL, NULL, 'largest_overlap')          AS block_rule,
    SAFE_DIVIDE(best.overlap_m2, best.db_area_m2)                AS overlap_share,
    db.source_url,
    db._synced_at
FROM db
LEFT JOIN best USING (dbuid)
