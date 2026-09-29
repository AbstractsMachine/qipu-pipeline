-- =============================================================================
-- Core: Fiscal Data source catalog — one row per synced endpoint (provenance dim)
--
-- Source: stg_us_fiscaldata_catalog (grain endpoint × column_name). This
--         model collapses it to the endpoint grain, dataset-level fields only.
-- Grain:  source_id (one row per configs/countries/us.yaml Fiscal Data source).
--
-- Same role as core_us_sf_source_catalog: the national marts (daily bread,
-- debt series) stamp provenance from here instead of reading staging
-- directly (ADR-0001 layering, rule E3). Per-field definitions stay in the
-- staging model.
-- =============================================================================

SELECT DISTINCT
    source_id,
    dataset_id,
    dataset_title,
    dataset_page_url,
    publisher,
    api_id,
    table_name,
    table_description,
    row_definition,
    endpoint,
    update_frequency,
    api_last_updated,
    earliest_date,
    latest_date,
    row_count
FROM {{ ref('stg_us_fiscaldata_catalog') }}
