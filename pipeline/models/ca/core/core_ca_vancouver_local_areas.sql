-- =============================================================================
-- Core: the 22 local areas, with a stable index. The map's neighbourhoods:
-- `area_idx` is what a block's one-byte `hood` field holds, joined on the
-- INDEX, never on the name (the SF rule, ADR-0012 §4.6). Ordered by name so
-- the index is stable across rebuilds.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core', 'citymap']) }}

SELECT
    ROW_NUMBER() OVER (ORDER BY local_area) - 1 AS area_idx,
    local_area,
    geog,
    ST_AREA(geog)                               AS area_m2,
    _synced_at
FROM {{ ref('stg_ca_vancouver_local_areas') }}
WHERE geog IS NOT NULL
