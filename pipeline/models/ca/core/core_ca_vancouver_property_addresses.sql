-- =============================================================================
-- Core: civic address points with the map block each one stands in.
--
-- Grain: one row per address point (the register's). block_idx is the block
-- whose outline contains the point, NULL where it falls outside every block
-- (a point on a street or the water). Used by the map's search to find the
-- block any address is on (mart_ca_vancouver_city_address_faces).
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core', 'citymap']) }}

SELECT
    a.civic_number, a.civic_int, a.std_street, a.pcoord, a.site_id, a.local_area, a.lon, a.lat,
    b.block_idx,
    a._synced_at
FROM {{ ref('stg_ca_vancouver_property_addresses') }} a
LEFT JOIN {{ ref('core_ca_vancouver_blocks') }} b
    ON ST_CONTAINS(b.geog, ST_GEOGPOINT(a.lon, a.lat))
WHERE a.lon IS NOT NULL AND a.lat IS NOT NULL
-- a point on the shared edge of two outlines is inside both; it stays one
-- address, on the smaller block (then the lower index, so the choice is stable)
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY TO_JSON_STRING(STRUCT(a.site_id, a.civic_number, a.std_street, a.pcoord, a.lon, a.lat))
    ORDER BY b.area_m2 IS NULL, b.area_m2, b.block_idx) = 1
