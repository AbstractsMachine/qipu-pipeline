-- =============================================================================
-- Core: parks, one row per published polygon.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core', 'citymap']) }}

SELECT
    ROW_NUMBER() OVER (ORDER BY park_name, park_object_id) - 1 AS park_idx,
    park_object_id, park_name, park_url, local_area, classification, area_ha,
    geog, _synced_at
FROM {{ ref('stg_ca_vancouver_parks') }}
WHERE geog IS NOT NULL
