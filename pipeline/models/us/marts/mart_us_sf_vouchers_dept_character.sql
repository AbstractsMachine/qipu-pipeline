-- =============================================================================
-- Mart: SF vendor payments (vouchers), department × character cells —
-- "who actually got paid" for a slice of the adopted budget
--
-- Sources: core_us_sf_vouchers, int_us_sf_payees (display bucket),
--          core_us_sf_source_catalog (provenance).
-- Grain:  fiscal_year × department × character × vendor, ranked within
--         cell by $, top 15 vendors kept per cell.
--
-- WHY dept×character, NOT dept×object (measured, docs/us/block-studies/
-- 1-budget.md §6 — the join test): dollar-vs-dollar match between adopted
-- budget and voucher payments is 90.3% of nonzero-budget $ at dept×
-- character and does NOT improve at dept×object — budget often sits on a
-- "-Budget" placeholder object code while payments post to a sibling
-- detail code (e.g. DPH FY2024 budgets $10.9M at object 538000 "CBO
-- Services - Budget" and $0 at 538010 "Community Based Org Srvcs" where
-- the vouchers actually land). Object-level payment DETAIL still renders
-- (objects_top3 upstream in mart_us_sf_top_payees) — this mart is the
-- dept×character comparison grain only.
--
-- cell_total_usd / cell_n_vendors are windowed BEFORE the top-15 cut, so
-- they stay accurate even though individual vendor rows are truncated —
-- the export computes "N more vendors, $X" from the gap.
-- =============================================================================

WITH vouchers AS (
    SELECT *
    FROM {{ ref('core_us_sf_vouchers') }}
    WHERE vendor IS NOT NULL
      AND department_code IS NOT NULL
      AND character_code IS NOT NULL
),

by_vendor AS (
    SELECT
        fiscal_year,
        department_code,
        department,
        character_code,
        character,
        vendor,
        SUM(vouchers_paid)                       AS vouchers_paid_usd,
        COUNT(DISTINCT voucher)                  AS n_vouchers,
        LOGICAL_OR(is_non_profit)                AS is_non_profit,
        LOGICAL_OR(is_related_govt_unit)         AS is_related_govt_unit,
        LOGICAL_AND(is_fiscal_year_complete)     AS is_fiscal_year_complete
    FROM vouchers
    GROUP BY 1, 2, 3, 4, 5, 6
),

cell_agg AS (
    -- Windowed over ALL vendors in the cell (net of negatives/refunds),
    -- BEFORE the ranking filter below — the honest cell total.
    SELECT
        fiscal_year,
        department_code,
        character_code,
        SUM(vouchers_paid_usd)             AS cell_total_usd,
        COUNT(DISTINCT vendor)             AS cell_n_vendors
    FROM by_vendor
    GROUP BY 1, 2, 3
),

ranked AS (
    SELECT
        v.*,
        ROW_NUMBER() OVER (
            PARTITION BY v.fiscal_year, v.department_code, v.character_code
            ORDER BY v.vouchers_paid_usd DESC, v.vendor
        ) AS rank_in_cell
    FROM by_vendor v
    WHERE v.vouchers_paid_usd > 0.005  -- ranked vendor list excludes net-negative/refund rows (never in share/length visuals); cell_agg above already captured the true net total
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
    r.department_code,
    r.department,
    r.character_code,
    r.character,
    r.vendor,
    r.vouchers_paid_usd,
    r.n_vouchers,
    r.is_non_profit,
    r.is_related_govt_unit,
    r.rank_in_cell,
    ca.cell_total_usd,
    ca.cell_n_vendors,
    pb.bucket,
    COALESCE(pb.is_aggregation_line, FALSE)  AS is_aggregation_line,
    r.is_fiscal_year_complete,
    {{ us_sf_execution_status('r.fiscal_year', basis='actuals') }}  AS execution_status,
    pr.dataset_id                          AS source_dataset_id,
    pr.dataset_name                        AS source_name,
    pr.dataset_page_url                    AS source_url,
    pr.attribution                         AS source_attribution,
    pr.rows_updated_at                     AS source_rows_updated_at,
    'USD'                                  AS unit
FROM ranked r
INNER JOIN cell_agg ca USING (fiscal_year, department_code, character_code)
LEFT JOIN {{ ref('int_us_sf_payees') }} pb
    ON pb.vendor = r.vendor
CROSS JOIN provenance pr
WHERE r.rank_in_cell <= 15
