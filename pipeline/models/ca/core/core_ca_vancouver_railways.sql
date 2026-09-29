-- =============================================================================
-- Core: railway track alignments, one row per published segment. `kind` is
-- the engine's transit vocabulary: the Downtown Historic Railway is a
-- heritage streetcar; every other operator (CN, CP, BNSF, VIA…) is 'other'.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core', 'citymap']) }}

SELECT
    operator_name,
    CASE WHEN operator_name = 'Downtown Historical Railway' THEN 'streetcar' ELSE 'other' END AS kind,
    geog,
    ST_LENGTH(geog) AS length_m,
    _synced_at
FROM {{ ref('stg_ca_vancouver_railways') }}
WHERE geog IS NOT NULL
