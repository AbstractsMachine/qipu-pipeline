-- =============================================================================
-- Core: Paris source catalog — one row per synced ODS dataset (provenance dim)
--
-- Source: stg_paris_catalog (grain dataset × field), collapsed to the dataset
--         grain; dataset-level fields only.
-- Grain:  source_id (one row per ods_dataset source in configs/cities/paris.yaml).
--
-- Same role as core_us_sf_source_catalog: Paris core/mart models join it to
-- stamp source_url / rows_updated_at instead of hardcoding a dataset URL in
-- SQL (first consumer: core_dette_garantie). Per-field metadata stays in
-- staging.
-- =============================================================================

{{ config(materialized='table', schema='analytics', tags=['core', 'catalog']) }}

-- `synced_at` : dernier passage de notre sync sur ce dataset (stamp
-- `_synced_at` du snapshot catalogue). Porté ici pour que mart_source_freshness
-- — et donc l'export data_freshness — n'aient jamais à lire le staging
-- (règle E4 du layering : un export ne lit que des marts).
SELECT
    source_id,
    dataset_id,
    dataset_title,
    dataset_page_url,
    domain,
    portal_name,
    publisher,
    license_title,
    license_url,
    theme,
    rows_updated_at,
    data_processed_at,
    records_count,
    MAX(_synced_at) AS synced_at
FROM {{ ref('stg_paris_catalog') }}
GROUP BY
    source_id, dataset_id, dataset_title, dataset_page_url, domain, portal_name,
    publisher, license_title, license_url, theme, rows_updated_at,
    data_processed_at, records_count
