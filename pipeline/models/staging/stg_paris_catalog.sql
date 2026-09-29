-- =============================================================================
-- Staging: Opendatasoft catalog snapshot (Paris) — typed, one-to-one with raw
--
-- Source: raw.paris_catalog (one row per synced dataset × field, from
--         /api/explore/v2.1/catalog/datasets/{id} — snapshotted by
--         sync_ods_dataset.py each run)
--
-- Provenance source of truth for Paris models: dataset title, opendata.paris.fr
-- dataset page URL, license, publisher, `modified` (the portal's refresh
-- timestamp → rows_updated_at). Same pattern as stg_us_sf_catalog.
-- =============================================================================

{{ config(materialized='view', schema='staging', tags=['staging', 'catalog']) }}

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
FROM {{ source('paris_raw', 'paris_catalog') }}
