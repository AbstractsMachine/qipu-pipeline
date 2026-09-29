-- =============================================================================
-- Mart: SF payees search index — one row per vendor, lazy-loaded by the UI
--
-- Sources: core_us_sf_vouchers, int_us_sf_payees, core_us_sf_source_catalog.
-- Grain:  vendor (union of every fiscal year's top 1,000 payees by $ —
--         measured 4,068 vendors covering ≈95-97% of every FY's dollars,
--         docs/us/block-studies/2-payees.md §2.2). The all-time universe is
--         71,710 raw names; the tail beyond the union is $-immaterial for
--         search and contains most person-like names (privacy: kept out).
--
-- Feeds payees_search.json — the Paris beneficiaires_search.json pattern:
-- fetched on first query, searched client-side. by_year carries the
-- vendor's FULL per-FY series (not just years where it made the top 1,000).
-- `bucket` rides along so person-bucket rows can render per the
-- personnes-physiques doctrine (labeled "individual payee", never featured).
-- =============================================================================

WITH by_vendor_fy AS (
    SELECT
        fiscal_year,
        vendor,
        SUM(vouchers_paid)          AS usd,
        LOGICAL_OR(is_non_profit)   AS is_non_profit_fy
    FROM {{ ref('core_us_sf_vouchers') }}
    WHERE vendor IS NOT NULL
    GROUP BY 1, 2
),

ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY fiscal_year ORDER BY usd DESC, vendor
        ) AS rank_in_fy
    FROM by_vendor_fy
),

index_vendors AS (
    SELECT DISTINCT vendor
    FROM ranked
    WHERE rank_in_fy <= 1000
),

vendor_rollup AS (
    SELECT
        vendor,
        SUM(usd)                          AS total_usd,
        MIN(fiscal_year)                  AS first_fy,
        MAX(fiscal_year)                  AS last_fy,
        MAX(IF(usd > 0, fiscal_year, NULL)) AS last_active_fy,
        COUNT(DISTINCT fiscal_year)       AS n_fys,
        LOGICAL_OR(is_non_profit_fy)      AS is_non_profit,
        ARRAY_AGG(
            STRUCT(fiscal_year, CAST(usd AS FLOAT64) AS usd)
            ORDER BY fiscal_year
        ) AS by_year
    FROM by_vendor_fy
    WHERE vendor IN (SELECT vendor FROM index_vendors)
    GROUP BY vendor
),

top_department AS (
    -- all-time biggest paying department per vendor
    SELECT vendor, department AS top_department, n_departments
    FROM (
        SELECT
            vendor, department,
            COUNT(DISTINCT department) OVER (PARTITION BY vendor) AS n_departments,
            ROW_NUMBER() OVER (
                PARTITION BY vendor ORDER BY SUM(vouchers_paid) DESC, department
            ) AS rn
        FROM {{ ref('core_us_sf_vouchers') }}
        WHERE vendor IS NOT NULL
        GROUP BY vendor, department
    )
    WHERE rn = 1
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
    vr.vendor,
    vr.total_usd,
    vr.first_fy,
    vr.last_fy,
    vr.last_active_fy,
    vr.n_fys,
    vr.is_non_profit,
    vr.by_year,
    td.top_department,
    td.n_departments,
    pb.bucket,
    COALESCE(pb.is_aggregation_line, FALSE) AS is_aggregation_line,
    pr.dataset_id                          AS source_dataset_id,
    pr.dataset_name                        AS source_name,
    pr.dataset_page_url                    AS source_url,
    pr.attribution                         AS source_attribution,
    pr.rows_updated_at                     AS source_rows_updated_at,
    'USD'                                  AS unit
FROM vendor_rollup vr
LEFT JOIN top_department td USING (vendor)
LEFT JOIN {{ ref('int_us_sf_payees') }} pb
    ON pb.vendor = vr.vendor
CROSS JOIN provenance pr
