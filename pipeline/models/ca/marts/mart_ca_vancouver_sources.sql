-- =============================================================================
-- Mart: every portal dataset the Vancouver pages read, one row per dataset,
-- from the catalog snapshot the sync writes (title, page, licence, the City's
-- last update, record count). The sources page lists it; nothing is typed in.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

SELECT
    source_id,
    dataset_id,
    dataset_title,
    dataset_page_url,
    publisher,
    license_title,
    license_url,
    theme,
    rows_updated_at,
    records_count,
    synced_at
FROM {{ ref('core_ca_vancouver_source_catalog') }}
