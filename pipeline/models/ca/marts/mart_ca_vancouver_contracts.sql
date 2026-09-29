-- =============================================================================
-- Mart: bid responses, row-level, with provenance — feeds contracts.json
-- (the explorer's lazy-search file and every competition fiche's bidder
-- table). Vendors are organisations; the City publishes the names.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH cat AS (
    SELECT dataset_title, dataset_page_url, license_title, rows_updated_at
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
    WHERE source_id = 'awarded_contracts'
)

SELECT
    c.response_id, c.bid_number, c.bid_type, c.bid_type_group, c.bid_description,
    c.award_date, c.award_year, c.vendor_name, c.vendor_key, c.bid_amount_cad,
    c.counted_amount_cad, c.is_shared_amount, c.n_sharing_winners,
    c.awarded, c.is_awarded,
    'CAD' AS unit,
    cat.dataset_title AS source_name, cat.dataset_page_url AS source_url,
    cat.license_title AS source_license, cat.rows_updated_at AS source_rows_updated_at
FROM {{ ref('core_ca_vancouver_contracts') }} c
CROSS JOIN cat
