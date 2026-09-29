-- =============================================================================
-- Mart: the city map's buildings — row-level, exactly the core rows, with the
-- provenance of every source that fed them stamped from the catalog. Read by
-- pipeline/scripts/ca_vancouver_city/encode_city_chunks.py (ADR-0012: the map's
-- export contract is manifest.json; its provenance comes from here).
-- LiDAR heights carry their own provenance columns (survey_id, dsm_url…) on stg.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts', 'citymap']) }}

WITH cat AS (
    SELECT
        ARRAY_AGG(STRUCT(source_id, dataset_title AS name, dataset_page_url AS url,
                         license_title AS license, rows_updated_at AS as_of)
                  ORDER BY source_id) AS sources
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
    WHERE source_id IN ('building_footprints_2015', 'property_parcel_polygons', 'property_tax_report_2025', 'block_outlines', 'local_area_boundary')
)

SELECT c.*, cat.sources
FROM {{ ref('core_ca_vancouver_buildings') }} c
CROSS JOIN cat
