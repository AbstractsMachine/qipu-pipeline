-- =============================================================================
-- Core: centrelines — public streets and lanes in one table, one row per
-- published segment. kind = 'street' | 'lane'. The street name is the City's
-- own label (hundred-block label minus its range for streets, std_street for
-- lanes); nothing is re-spelled.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core', 'citymap']) }}

WITH s AS (
    SELECT 'street' AS kind, street_name, street_use, hblock, geog, _synced_at
    FROM {{ ref('stg_ca_vancouver_public_streets') }}
    UNION ALL
    SELECT 'lane' AS kind, std_street AS street_name, 'Lane' AS street_use, from_hundred_block AS hblock, geog, _synced_at
    FROM {{ ref('stg_ca_vancouver_lanes') }}
)

SELECT
    ROW_NUMBER() OVER (ORDER BY kind, street_name, hblock, ST_ASTEXT(geog)) - 1 AS segment_idx,
    kind,
    street_name,
    street_use,
    hblock,
    geog,
    ST_LENGTH(geog) AS length_m,
    _synced_at
FROM s
WHERE geog IS NOT NULL
