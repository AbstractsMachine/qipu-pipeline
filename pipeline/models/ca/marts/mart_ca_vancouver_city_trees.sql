-- =============================================================================
-- Mart: the city map's trees — row-level, exactly the core rows, with the
-- provenance of every source that fed them stamped from the catalog. Read by
-- pipeline/scripts/ca_vancouver_city/encode_city_chunks.py (ADR-0012: the map's
-- export contract is manifest.json; its provenance comes from here).
-- 
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts', 'citymap']) }}

WITH cat AS (
    SELECT
        ARRAY_AGG(STRUCT(source_id, dataset_title AS name, dataset_page_url AS url,
                         license_title AS license, rows_updated_at AS as_of)
                  ORDER BY source_id) AS sources
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
    WHERE source_id IN ('public_trees')
)

SELECT c.*, cat.sources
FROM {{ ref('core_ca_vancouver_trees') }} c
CROSS JOIN cat
