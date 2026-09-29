-- =============================================================================
-- Core: Recife CKAN source catalog — one row per synced resource (provenance dim)
--
-- Source: stg_br_recife_catalog (already one row per resource).
-- Grain:  (source_id, resource_id). Yearly resources of one dataset keep
--         distinct source_ids (credor_2019, credor_2020, …); the family
--         roll-up (LIKE 'credor_%', MAX(rows_updated_at)) is the mart's call.
--
-- Same role as core_us_sf_source_catalog: marts stamp source_url / as_of
-- from this core instead of reading staging directly (ADR-0001, rule E3).
-- =============================================================================

SELECT
    source_id,
    resource_id,
    dataset_title,
    resource_name,
    resource_url,
    dataset_page_url,
    resource_page_url,
    portal_name,
    license_title,
    attribution,
    format,
    rows_updated_at
FROM {{ ref('stg_br_recife_catalog') }}
