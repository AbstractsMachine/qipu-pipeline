-- =============================================================================
-- Core: public trees, one row per tree with a location. planted_year is the
-- City's date_planted year where published (≈42 %); NULL means the register
-- does not say, and the map draws such a tree as already standing — it never
-- invents a year.
--
-- NOT EVERY ROW IS A TREE. The register carries its planting SITES and its
-- STUMPS as assets with genus_name 'PLANTING' (1,043) and 'STUMP' (632) —
-- measured 2026-09-13. Drawn as crowns they would put ~1,700 trees where
-- there are none, so they are excluded here and counted in the export note.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core', 'citymap']) }}

SELECT
    tree_id,
    common_name,
    genus_name,
    species_name,
    height_class_m,
    diameter_cm,
    date_planted,
    EXTRACT(YEAR FROM date_planted) AS planted_year,
    ST_X(geog)                      AS lon,
    ST_Y(geog)                      AS lat,
    _synced_at
FROM {{ ref('stg_ca_vancouver_public_trees') }}
WHERE geog IS NOT NULL AND ST_DIMENSION(geog) = 0
  AND COALESCE(genus_name, '') NOT IN ('PLANTING', 'STUMP')
