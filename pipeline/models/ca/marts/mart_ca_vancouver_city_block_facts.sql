-- =============================================================================
-- Mart: what stands on each city block now — who lives there and how many homes
-- — beside the block's record on the map (blocks/block-facts.json, written by
-- pipeline/scripts/ca_vancouver_city/build_blocks.py).
--
-- One row per city block (core_ca_vancouver_blocks). residents / homes are the
-- 2021 Census population and total private dwellings of the census blocks
-- attributed to this block (core_ca_vancouver_census_blocks, largest overlap);
-- NULL — not zero — where no census block is attributed here.
--
-- THE ROLL, PER BLOCK (core_ca_vancouver_parcels: the 2025 property tax report
-- joined to parcel polygons). A parcel is on the block its point falls in.
--   n_parcels       parcels on the roll here
--   n_folios        tax folios on those parcels — a strata building is one folio
--                   per unit, so this counts strata lots, NOT homes
--   assessed_cad    land + improvement value as assessed, not a market price
--   zoning          the zoning classification covering the most parcel area on
--                   the block. The roll records ZONING, not what stands there:
--                   the panel prints it as zoning, never as a use.
-- NULL where the roll places no parcel on the block.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts', 'citymap']) }}

WITH census AS (
    SELECT
        block_idx,
        SUM(population)  AS residents,
        SUM(dwellings)   AS homes,
        COUNT(*)         AS n_census_blocks,
        ANY_VALUE(source_url) AS source_url
    FROM {{ ref('core_ca_vancouver_census_blocks') }}
    WHERE block_idx IS NOT NULL
    GROUP BY block_idx
),

roll AS (
    SELECT b.block_idx, p.zoning_classification AS zoning, p.area_m2,
           p.n_properties, COALESCE(p.land_value_cad, 0) + COALESCE(p.improvement_value_cad, 0) AS assessed_cad,
           p.report_year
    FROM {{ ref('core_ca_vancouver_parcels') }} p
    JOIN {{ ref('core_ca_vancouver_blocks') }} b ON ST_CONTAINS(b.geog, ST_GEOGPOINT(p.lon, p.lat))
    WHERE p.lon IS NOT NULL AND p.has_roll_row
),
by_block AS (
    SELECT block_idx, COUNT(*) AS n_parcels, SUM(n_properties) AS n_folios, SUM(assessed_cad) AS assessed_cad,
           MAX(report_year) AS roll_year
    FROM roll GROUP BY block_idx
),
main_zoning AS (
    SELECT block_idx, zoning
    FROM (SELECT block_idx, zoning, SUM(area_m2) AS a FROM roll WHERE zoning IS NOT NULL GROUP BY 1, 2)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY block_idx ORDER BY a DESC, zoning) = 1
)

SELECT
    b.block_idx,
    b.area_idx,
    b.local_area,
    c.residents,
    c.homes,
    COALESCE(c.n_census_blocks, 0) AS n_census_blocks,
    2021                           AS census_year,
    (SELECT ANY_VALUE(source_url) FROM census) AS census_source_url,
    r.n_parcels,
    r.n_folios,
    r.assessed_cad,
    z.zoning,
    (SELECT MAX(roll_year) FROM by_block) AS roll_year
FROM {{ ref('core_ca_vancouver_blocks') }} b
LEFT JOIN census c USING (block_idx)
LEFT JOIN by_block r USING (block_idx)
LEFT JOIN main_zoning z USING (block_idx)
