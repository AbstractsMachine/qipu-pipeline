-- =============================================================================
-- Core: Vancouver source catalog — one row per synced ODS dataset (provenance dim)
--
-- Source: stg_ca_vancouver_catalog (grain dataset × field), collapsed to the
--         dataset grain. Grain: source_id (configs/cities/vancouver.yaml).
-- Every ca mart CROSS JOINs / joins this to stamp source_url, licence and
-- rows_updated_at (as_of) — never a hardcoded URL (ADR-0010 export contract).
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core', 'catalog']) }}

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
FROM {{ ref('stg_ca_vancouver_catalog') }}
GROUP BY
    source_id, dataset_id, dataset_title, dataset_page_url, domain, portal_name,
    publisher, license_title, license_url, theme, rows_updated_at,
    data_processed_at, records_count
