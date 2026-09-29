-- =============================================================================
-- Mart: SF payees — per-fiscal-year context for the who-gets-paid page
--
-- Sources: core_us_sf_vouchers, core_us_sf_contracts (grant join),
--          int_us_sf_payees, core_us_sf_source_catalog (provenance).
-- Grain:  fiscal_year (one row per FY, FY2007-FY2027).
--
-- Everything the page hero and per-year header need, measured not assumed
-- (docs/us/block-studies/2-payees.md):
--   - PERIMETER SPLIT: total = ALL payments through the City's financial
--     system, incl. is_related_govt_unit=true flows ($5.46B / 33% of
--     FY2025 — pension benefits, health-system premiums, GEN debt service,
--     college district). The split is exported so the hero can label it;
--     never netted silently (cross-cutting rule 4).
--     related_top_departments carries the top 4 related-entity department
--     lines so the label's composition comes from data, not copy.
--   - BUCKET COVERAGE per FY: share of vendor-attributed $ whose vendor is
--     classified in the seed. 65.6% FY2025 / 64.0% FY2026 vs ~26-32%
--     pre-2018 at seed v1 — the UI renders a coverage badge when low
--     (Paris "données brutes" honesty pattern).
--   - NONPROFIT slice (FY2018+ ONLY — non_profit_indicator is empty before
--     FY2018, measured 0 rows 2007-2017): totals, distinct orgs, share,
--     top department. NULL pre-2018, not 0.
--   - GRANT lens (FY2018+ ONLY — contract numbers start with PeopleSoft):
--     vouchers paid under 'Grant Contract%' contracts. NULL pre-2018.
--   - execution_status enum (cross-cutting rule 2).
-- =============================================================================

WITH vouchers AS (
    SELECT * FROM {{ ref('core_us_sf_vouchers') }}
),

totals AS (
    SELECT
        fiscal_year,
        SUM(vouchers_paid)                                        AS total_usd,
        SUM(IF(is_related_govt_unit, vouchers_paid, 0))           AS related_govt_units_usd,
        SUM(IF(NOT is_related_govt_unit, vouchers_paid, 0))       AS city_usd,
        COUNT(DISTINCT vendor)                                    AS n_vendors,
        COUNT(DISTINCT voucher)                                   AS n_vouchers
    FROM vouchers
    GROUP BY fiscal_year
),

by_vendor AS (
    SELECT
        fiscal_year,
        vendor,
        SUM(vouchers_paid) AS usd
    FROM vouchers
    WHERE vendor IS NOT NULL
    GROUP BY 1, 2
),

coverage AS (
    SELECT
        bv.fiscal_year,
        SAFE_DIVIDE(
            SUM(IF(pb.vendor IS NOT NULL, bv.usd, 0)),
            SUM(bv.usd)
        ) AS bucket_coverage_pct
    FROM by_vendor bv
    LEFT JOIN {{ ref('int_us_sf_payees') }} pb
        ON pb.vendor = bv.vendor
    GROUP BY 1
),

related_depts AS (
    SELECT
        fiscal_year,
        ARRAY_AGG(
            STRUCT(department, usd)
            ORDER BY usd DESC
            LIMIT 4
        ) AS related_top_departments
    FROM (
        SELECT fiscal_year, department, CAST(SUM(vouchers_paid) AS FLOAT64) AS usd
        FROM vouchers
        WHERE is_related_govt_unit
        GROUP BY 1, 2
        HAVING SUM(vouchers_paid) > 0
    )
    GROUP BY 1
),

nonprofit AS (
    SELECT
        fiscal_year,
        SUM(IF(is_non_profit, vouchers_paid, 0))                  AS nonprofit_usd,
        COUNT(DISTINCT IF(is_non_profit, vendor, NULL))           AS n_nonprofit_vendors
    FROM vouchers
    WHERE fiscal_year >= 2018
    GROUP BY 1
),

nonprofit_top_dept AS (
    SELECT fiscal_year, department AS top_nonprofit_department, usd AS top_nonprofit_department_usd
    FROM (
        SELECT
            fiscal_year, department, SUM(vouchers_paid) AS usd,
            ROW_NUMBER() OVER (
                PARTITION BY fiscal_year ORDER BY SUM(vouchers_paid) DESC, department
            ) AS rn
        FROM vouchers
        WHERE fiscal_year >= 2018 AND is_non_profit
        GROUP BY 1, 2
    )
    WHERE rn = 1
),

grant_contracts AS (
    SELECT DISTINCT contract_no
    FROM {{ ref('core_us_sf_contracts') }}
    WHERE contract_type LIKE 'Grant Contract%'
      AND contract_no IS NOT NULL
),

grants AS (
    SELECT
        v.fiscal_year,
        SUM(IF(g.contract_no IS NOT NULL, v.vouchers_paid, 0))                       AS grant_funded_usd,
        SUM(IF(g.contract_no IS NOT NULL AND v.is_non_profit, v.vouchers_paid, 0))   AS grant_funded_nonprofit_usd
    FROM vouchers v
    LEFT JOIN grant_contracts g
        ON g.contract_no = v.contract_number
    WHERE v.fiscal_year >= 2018
    GROUP BY 1
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
    t.fiscal_year,
    t.total_usd,
    t.city_usd,
    t.related_govt_units_usd,
    SAFE_DIVIDE(t.related_govt_units_usd, t.total_usd) AS related_share_of_total,
    rd.related_top_departments,
    t.n_vendors,
    t.n_vouchers,
    c.bucket_coverage_pct,
    np.nonprofit_usd,
    np.n_nonprofit_vendors,
    SAFE_DIVIDE(np.nonprofit_usd, t.total_usd)     AS nonprofit_share_of_total,
    ntd.top_nonprofit_department,
    ntd.top_nonprofit_department_usd,
    g.grant_funded_usd,
    g.grant_funded_nonprofit_usd,
    {{ us_sf_execution_status('t.fiscal_year', basis='actuals') }}  AS execution_status,
    pr.dataset_id                                  AS source_dataset_id,
    pr.dataset_name                                AS source_name,
    pr.dataset_page_url                            AS source_url,
    pr.attribution                                 AS source_attribution,
    pr.rows_updated_at                             AS source_rows_updated_at,
    'USD'                                          AS unit
FROM totals t
LEFT JOIN coverage c USING (fiscal_year)
LEFT JOIN related_depts rd USING (fiscal_year)
LEFT JOIN nonprofit np USING (fiscal_year)
LEFT JOIN nonprofit_top_dept ntd USING (fiscal_year)
LEFT JOIN grants g USING (fiscal_year)
CROSS JOIN provenance pr
