-- =============================================================================
-- Mart: SF top payees by fiscal year — vouchers paid per FY × vendor
--
-- Sources: core_us_sf_vouchers (8.07M rows → FY × vendor rollup),
--          core_us_sf_contracts (grant-contract join, FY2018+),
--          int_us_sf_payees (manual bucket classification),
--          core_us_sf_source_catalog (provenance).
-- Grain:  fiscal_year × vendor, top 100 payees per FY by vouchers_paid.
--
-- READ THIS before ranking (docs/us/API-RECON.md §A.3): the top of a naive
-- ranking is banks/fiscal agents (JPMorgan $1.86B FY2025 — debt service and
-- pass-throughs), NOT service providers. `bucket` annotates payees from the
-- MANUAL classification seed (fiscal_agent_debt_service /
-- payroll_passthrough / healthcare / nonprofit / supplier / other / person);
-- NULL bucket = unclassified. The seed join is per exact vendor string, so a
-- classified string carries its bucket into every fiscal year it appears in
-- (two-layer strategy, docs/us/block-studies/2-payees.md §2.4). Vendor
-- names are unkeyed portal strings (BNY Mellon appears under 2 spellings —
-- both classified in the seed).
--
-- Block 2 additions (2026-07-16):
--   objects_top3        — top 3 `object` labels by $ for the row (display
--                         context: "what they're paid for");
--   grant_funded_usd    — $ of the row's vouchers paid under contracts SF
--                         classifies as 'Grant Contract%' ("City as
--                         Grantor"); contract numbers exist FY2018+ only,
--                         so pre-2018 this is NULL, not 0;
--   is_aggregation_line — the Controller's aggregated vendor lines
--                         ('Single Payment Payees', …) that are NOT one
--                         entity and must never render as a plain payee;
--   execution_status    — closed / recently_closed_preliminary /
--                         in_progress (SF-BUILD-PLAN cross-cutting rule 2).
-- =============================================================================

WITH by_vendor AS (
    SELECT
        fiscal_year,
        vendor,
        SUM(vouchers_paid)                       AS vouchers_paid_usd,
        SUM(vouchers_pending)                    AS vouchers_pending_usd,
        COUNT(DISTINCT voucher)                  AS n_vouchers,
        COUNT(*)                                 AS n_voucher_lines,
        LOGICAL_OR(is_non_profit)                AS is_non_profit,
        COUNT(DISTINCT department)               AS n_departments,
        LOGICAL_AND(is_fiscal_year_complete)     AS is_fiscal_year_complete
    FROM {{ ref('core_us_sf_vouchers') }}
    WHERE vendor IS NOT NULL
    GROUP BY fiscal_year, vendor
),

top_department AS (
    -- biggest paying department per (FY, vendor), for display context
    SELECT fiscal_year, vendor, department AS top_department
    FROM (
        SELECT
            fiscal_year, vendor, department,
            ROW_NUMBER() OVER (
                PARTITION BY fiscal_year, vendor
                ORDER BY SUM(vouchers_paid) DESC, department
            ) AS rn
        FROM {{ ref('core_us_sf_vouchers') }}
        WHERE vendor IS NOT NULL
        GROUP BY fiscal_year, vendor, department
    )
    WHERE rn = 1
),

fy_totals AS (
    SELECT
        fiscal_year,
        SUM(vouchers_paid_usd) AS fy_total_vouchers_paid_usd
    FROM by_vendor
    GROUP BY fiscal_year
),

ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY fiscal_year ORDER BY vouchers_paid_usd DESC, vendor
        ) AS rank_in_fy
    FROM by_vendor
),

top_rows AS (
    SELECT fiscal_year, vendor
    FROM ranked
    WHERE rank_in_fy <= 100
),

-- top 3 objects by $ per (FY, vendor) — only computed for exported rows
objects_ranked AS (
    SELECT
        v.fiscal_year,
        v.vendor,
        v.object,
        SUM(v.vouchers_paid) AS usd
    FROM {{ ref('core_us_sf_vouchers') }} v
    INNER JOIN top_rows USING (fiscal_year, vendor)
    WHERE v.object IS NOT NULL
    GROUP BY 1, 2, 3
    HAVING SUM(v.vouchers_paid) > 0
),

objects_top3 AS (
    SELECT
        fiscal_year,
        vendor,
        ARRAY_AGG(object ORDER BY usd DESC LIMIT 3) AS objects_top3
    FROM objects_ranked
    GROUP BY 1, 2
),

-- vouchers paid under 'Grant Contract%' contracts (City as Grantor).
-- 0 conflicting contract_no measured (2026-07-16); DISTINCT keeps the
-- join key unique.
grant_contracts AS (
    SELECT DISTINCT contract_no
    FROM {{ ref('core_us_sf_contracts') }}
    WHERE contract_type LIKE 'Grant Contract%'
      AND contract_no IS NOT NULL
),

grant_funded AS (
    SELECT
        v.fiscal_year,
        v.vendor,
        SUM(v.vouchers_paid) AS grant_funded_usd
    FROM {{ ref('core_us_sf_vouchers') }} v
    INNER JOIN top_rows USING (fiscal_year, vendor)
    INNER JOIN grant_contracts g
        ON g.contract_no = v.contract_number
    GROUP BY 1, 2
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
    r.vendor,
    r.vouchers_paid_usd,
    r.vouchers_pending_usd,
    r.n_vouchers,
    r.n_voucher_lines,
    r.is_non_profit,
    r.n_departments,
    td.top_department,
    o3.objects_top3,
    gf.grant_funded_usd,
    r.is_fiscal_year_complete,
    {{ us_sf_execution_status('r.fiscal_year', basis='actuals') }}  AS execution_status,
    SAFE_DIVIDE(r.vouchers_paid_usd, ft.fy_total_vouchers_paid_usd)  AS share_of_fy_paid,
    ft.fy_total_vouchers_paid_usd,
    pb.bucket,
    pb.classification_note,
    pb.classification_method,
    pb.classified_at,
    COALESCE(pb.is_aggregation_line, FALSE) AS is_aggregation_line,
    pr.dataset_id                          AS source_dataset_id,
    pr.dataset_name                        AS source_name,
    pr.dataset_page_url                    AS source_url,
    pr.attribution                         AS source_attribution,
    pr.rows_updated_at                     AS source_rows_updated_at,
    'USD'                                  AS unit
FROM ranked r
INNER JOIN fy_totals ft USING (fiscal_year)
LEFT JOIN top_department td USING (fiscal_year, vendor)
LEFT JOIN objects_top3 o3 USING (fiscal_year, vendor)
LEFT JOIN grant_funded gf USING (fiscal_year, vendor)
LEFT JOIN {{ ref('int_us_sf_payees') }} pb
    ON pb.vendor = r.vendor
CROSS JOIN provenance pr
WHERE r.rank_in_fy <= 100
