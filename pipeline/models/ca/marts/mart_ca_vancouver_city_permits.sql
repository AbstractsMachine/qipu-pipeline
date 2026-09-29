-- Mart: new-building and demolition permits for the map's dots, with the block
-- each stands in and provenance (build_record.py).

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts', 'citymap']) }}

WITH cat AS (
    SELECT ARRAY_AGG(STRUCT(source_id, dataset_title AS name, dataset_page_url AS url,
                            license_title AS license, rows_updated_at AS as_of)) AS sources
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
    WHERE source_id = 'issued_building_permits'
)
SELECT p.*, b.block_idx, cat.sources
FROM {{ ref('core_ca_vancouver_building_permits') }} p
LEFT JOIN {{ ref('core_ca_vancouver_blocks') }} b ON ST_CONTAINS(b.geog, ST_GEOGPOINT(p.lon, p.lat))
CROSS JOIN cat
WHERE p.work_class IN ('new_building', 'demolition')
