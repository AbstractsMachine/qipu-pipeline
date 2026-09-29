-- =============================================================================
-- Mart: SF top nonprofit payees per fiscal year — FY2018+ ONLY
--
-- Sources: core_us_sf_vouchers (is_non_profit flag), core_us_sf_contracts
--          (grant join), int_us_sf_payees, core_us_sf_source_catalog.
-- Grain:  fiscal_year × vendor, top 30 nonprofit-flagged payees per FY.
--
-- FLOOR (measured, docs/us/block-studies/2-payees.md §1.3):
-- non_profit_indicator is EMPTY before FY2018 (0 rows 2007-2017) — the
-- PeopleSoft migration introduced the flag. This mart therefore starts at
-- FY2018 and the UI renders a floor note; no name-based backfill (would be
-- honest-incomplete at 13.8% of pre-2018 $).
--
-- COMMUNITY RANKING (in_community_ranking + community_rank): the raw
-- nonprofit ranking is topped by Kaiser ($4.35B all-time — employee health
-- premiums), UC Regents and City College — real nonprofits, but not the
-- community-services story. Rows whose bucket is 'healthcare', 'other'
-- (intergovernmental / assessment pass-throughs) or any non-nonprofit
-- bucket are EXCLUDED from community_rank and shown by the UI in a labeled
-- "also flagged nonprofit" note instead. Unclassified (NULL-bucket)
-- flagged vendors stay IN — they are the community long tail.
-- =============================================================================

WITH grant_contracts AS (
    SELECT DISTINCT contract_no
    FROM {{ ref('core_us_sf_contracts') }}
    WHERE contract_type LIKE 'Grant Contract%'
      AND contract_no IS NOT NULL
),

by_vendor AS (
    SELECT
        v.fiscal_year,
        v.vendor,
        SUM(v.vouchers_paid)                                       AS vouchers_paid_usd,
        SUM(IF(g.contract_no IS NOT NULL, v.vouchers_paid, 0))     AS grant_funded_usd,
        COUNT(DISTINCT v.voucher)                                  AS n_vouchers,
        COUNT(DISTINCT v.department)                               AS n_departments
    FROM {{ ref('core_us_sf_vouchers') }} v
    LEFT JOIN grant_contracts g
        ON g.contract_no = v.contract_number
    WHERE v.fiscal_year >= 2018
      AND v.is_non_profit
      AND v.vendor IS NOT NULL
    GROUP BY 1, 2
),

fy_np_totals AS (
    SELECT
        fiscal_year,
        SUM(vouchers_paid_usd) AS fy_nonprofit_total_usd
    FROM by_vendor
    GROUP BY 1
),

top_department AS (
    SELECT fiscal_year, vendor, department AS top_department
    FROM (
        SELECT
            fiscal_year, vendor, department,
            ROW_NUMBER() OVER (
                PARTITION BY fiscal_year, vendor
                ORDER BY SUM(vouchers_paid) DESC, department
            ) AS rn
        FROM {{ ref('core_us_sf_vouchers') }}
        WHERE fiscal_year >= 2018 AND is_non_profit AND vendor IS NOT NULL
        GROUP BY fiscal_year, vendor, department
    )
    WHERE rn = 1
),

ranked AS (
    SELECT
        bv.*,
        pb.bucket,
        pb.classification_note,
        COALESCE(pb.is_aggregation_line, FALSE) AS is_aggregation_line,
        -- community = classic service nonprofits: seed-nonprofit or
        -- unclassified; every other bucket is excluded from the ranking.
        (pb.bucket IS NULL OR pb.bucket = 'nonprofit')
            AND NOT COALESCE(pb.is_aggregation_line, FALSE) AS in_community_ranking,
        ROW_NUMBER() OVER (
            PARTITION BY bv.fiscal_year ORDER BY bv.vouchers_paid_usd DESC, bv.vendor
        ) AS rank_in_fy
    FROM by_vendor bv
    LEFT JOIN {{ ref('int_us_sf_payees') }} pb
        ON pb.vendor = bv.vendor
),

community_ranked AS (
    SELECT
        fiscal_year,
        vendor,
        ROW_NUMBER() OVER (
            PARTITION BY fiscal_year ORDER BY vouchers_paid_usd DESC, vendor
        ) AS community_rank
    FROM ranked
    WHERE in_community_ranking
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
    r.fiscal_year,
    r.rank_in_fy,
    cr.community_rank,
    r.in_community_ranking,
    r.vendor,
    r.vouchers_paid_usd,
    r.grant_funded_usd,
    r.n_vouchers,
    r.n_departments,
    td.top_department,
    r.bucket,
    r.classification_note,
    ft.fy_nonprofit_total_usd,
    SAFE_DIVIDE(r.vouchers_paid_usd, ft.fy_nonprofit_total_usd) AS share_of_fy_nonprofit,
    {{ us_sf_execution_status('r.fiscal_year', basis='actuals') }}  AS execution_status,
    pr.dataset_id                          AS source_dataset_id,
    pr.dataset_name                        AS source_name,
    pr.dataset_page_url                    AS source_url,
    pr.attribution                         AS source_attribution,
    pr.rows_updated_at                     AS source_rows_updated_at,
    'USD'                                  AS unit
FROM ranked r
INNER JOIN fy_np_totals ft USING (fiscal_year)
LEFT JOIN community_ranked cr USING (fiscal_year, vendor)
LEFT JOIN top_department td USING (fiscal_year, vendor)
CROSS JOIN provenance pr
WHERE r.rank_in_fy <= 30
