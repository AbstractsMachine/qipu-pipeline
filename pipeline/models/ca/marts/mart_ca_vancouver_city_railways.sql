-- Mart: the city map's railways — row-level core rows with catalog provenance
-- (read by pipeline/scripts/ca_vancouver_city/encode_city_chunks.py).

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts', 'citymap']) }}

WITH cat AS (
    SELECT ARRAY_AGG(STRUCT(source_id, dataset_title AS name, dataset_page_url AS url,
                            license_title AS license, rows_updated_at AS as_of)) AS sources
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
    WHERE source_id = 'railways'
)
SELECT c.*, cat.sources FROM {{ ref('core_ca_vancouver_railways') }} c CROSS JOIN cat
