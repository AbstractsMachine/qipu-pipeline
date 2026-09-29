-- =============================================================================
-- Mart: the largest AWARDS — for the hub deck/marquee. Top 25 awarded
-- responses by amount (losing bids excluded), provenance from the catalog.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH cat AS (
    SELECT dataset_title, dataset_page_url, license_title, rows_updated_at
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
    WHERE source_id = 'awarded_contracts'
)

SELECT
    c.bid_number, c.bid_type, c.bid_type_group, c.bid_description, c.award_date, c.award_year,
    c.vendor_name, c.vendor_key, c.bid_amount_cad, c.n_sharing_winners,
    'CAD' AS unit,
    cat.dataset_title AS source_name, cat.dataset_page_url AS source_url,
    cat.license_title AS source_license, cat.rows_updated_at AS source_rows_updated_at
FROM {{ ref('core_ca_vancouver_contracts') }} c
CROSS JOIN cat
-- a shared amount printed beside several winners is one award here (the row
-- counted in core), with n_sharing_winners to say so
WHERE c.is_awarded AND c.bid_amount_cad IS NOT NULL AND c.counted_amount_cad = c.bid_amount_cad
ORDER BY c.bid_amount_cad DESC
LIMIT 25
