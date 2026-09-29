-- =============================================================================
-- Mart: SF payee materiality lines — "what a payment buys"
--
-- Sources: int_us_sf_payee_materiality (curated picks + measured amounts)
--          (the amounts), core_us_sf_source_catalog (provenance).
-- Grain:  one row per curated line (slug).
--
-- The seed picks WHICH (vendor × department × sub_object × fiscal_year)
-- lines to feature — jail meals, election interpreters, Port lumber, Fire
-- uniforms, Muni light-rail cars, homelessness building purchases (all
-- verified against live vouchers 2026-07-16, docs/us/block-studies/
-- 2-payees.md §1.7). The DOLLAR AMOUNT is always computed here from the
-- voucher rows (zero-hardcode). INNER JOIN: a pick that stops matching
-- disappears from the export and fails
-- tests/us/assert_us_sf_materiality_rows_match.sql.
-- =============================================================================

WITH picks AS (
    SELECT * FROM {{ ref('int_us_sf_payee_materiality') }}
),

provenance AS (
    SELECT DISTINCT
        dataset_id,
        dataset_name,
        dataset_page_url,
        attribution,
        rows_updated_at
    FROM {{ ref('core_us_sf_source_catalog') }}
    WHERE source_id = 'sf_vouchers'
)

SELECT
    p.slug,
    p.label,
    p.editorial_note,
    p.vendor,
    p.department,
    p.object,
    p.sub_object,
    p.fiscal_year,
    p.amount_usd,
    p.n_voucher_lines,
    {{ us_sf_execution_status('p.fiscal_year', basis='actuals') }}  AS execution_status,
    p.method                               AS curation_method,
    p.added_at                             AS curated_at,
    pr.dataset_id                          AS source_dataset_id,
    pr.dataset_name                        AS source_name,
    pr.dataset_page_url                    AS source_url,
    pr.attribution                         AS source_attribution,
    pr.rows_updated_at                     AS source_rows_updated_at,
    'USD'                                  AS unit
FROM picks p
CROSS JOIN provenance pr
