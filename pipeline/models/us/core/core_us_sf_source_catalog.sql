-- =============================================================================
-- Core: DataSF source catalog — one row per synced dataset (provenance dim)
--
-- Source: stg_us_sf_catalog (grain dataset × column). This model collapses
--         it to the dataset grain and keeps only the dataset-level fields.
-- Grain:  source_id (one row per configs/countries/us.yaml Socrata source).
--
-- Why it exists: every SF mart stamps its rows with dataset_page_url /
-- rows_updated_at (the export data contract, ADR-0010 D2). Before this dim
-- each mart re-derived that from the staging table directly, which breaks
-- the layering rule (mart_* reads core_*/int_* only — ADR-0001, E3). The
-- provenance join now lives here, the marts read the core.
-- Per-column metadata (display names, types) stays in stg_us_sf_catalog;
-- no mart needs it.
-- =============================================================================

SELECT DISTINCT
    source_id,
    dataset_id,
    dataset_name,
    dataset_description,
    dataset_page_url,
    domain,
    portal_name,
    attribution,
    category,
    rows_updated_at,
    created_at,
    publication_date
FROM {{ ref('stg_us_sf_catalog') }}
