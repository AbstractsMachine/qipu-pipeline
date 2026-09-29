-- =============================================================================
-- Core: PARCEL POLYGONS — one row per published polygon (the ground the map
-- draws). Grain: polygon, as the City publishes it. Keeps the polygons that
-- carry NO tax_coord (unassessed land — roads, lanes, parks) because the map
-- must draw them even though nothing can be dated or valued on them.
--
-- A parcel (tax_coord) is drawn as SEVERAL polygons when it is multi-part —
-- 1725 E Broadway is twelve pieces from 9 m² to 1,497 m². The money unit is
-- the PARCEL, dissolved in core_ca_vancouver_parcels; this table is the
-- geometry unit. Row count == staging (tested).
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

SELECT
    ROW_NUMBER() OVER (ORDER BY tax_coord, site_id, ST_ASTEXT(parcel_geog)) AS polygon_id,
    tax_coord,
    site_id,
    civic_number,
    street_name,
    parcel_geog,
    lon,
    lat,
    ST_AREA(parcel_geog)  AS area_m2,
    tax_coord IS NOT NULL AS has_tax_coord,
    _synced_at
FROM {{ ref('stg_ca_vancouver_parcels') }}
