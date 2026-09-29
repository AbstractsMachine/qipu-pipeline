-- =============================================================================
-- Staging: Opendatasoft catalog snapshot (Vancouver) — typed, one-to-one with raw
--
-- Source: raw.ca_vancouver_catalog (one row per synced dataset × field, from
--         /api/explore/v2.1/catalog/datasets/{id}, snapshotted by
--         sync_ods_dataset.py --city vancouver each run).
-- Provenance source of truth for every ca_vancouver model: dataset title,
-- portal page URL, licence (Open Government Licence – Vancouver), publisher,
-- `modified` → rows_updated_at. Same pattern as stg_paris_catalog.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'catalog']) }}

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
    SAFE_CAST(rows_updated_at AS TIMESTAMP)   AS rows_updated_at,
    SAFE_CAST(data_processed_at AS TIMESTAMP) AS data_processed_at,
    SAFE_CAST(records_count AS INT64)         AS records_count,
    column_field_name,
    column_display_name,
    column_data_type,
    column_description,
    SAFE_CAST(column_position AS INT64)       AS column_position,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_catalog') }}
