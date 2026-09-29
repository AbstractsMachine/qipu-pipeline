-- =============================================================================
-- Mart: normalized SF payees — the top 200 by lifetime dollars paid
--
-- Sources: core_us_sf_vouchers (payee_slug / payee_name joined row-level from
--          the identity seed), int_us_sf_payees (manual bucket), core_us_sf_source_catalog.
-- Grain:   payee_slug.
--
-- A payee is one or more raw vendor strings ("BANK OF NEW YORK" / "BNY
-- MELLON") folded by build_sf_payee_identity.py. Dollars are summed over every
-- variant; by_year is the complete per-FY series; variants keeps each spelling
-- with its own total (and the curated merge reason when there is one).
-- kind: the manual bucket of any variant (first non-'other'), else 'nonprofit'
-- when the Controller flags any variant non-profit, else 'other'.
-- Aggregation lines ("SINGLE PAYMENT PAYEES") never get an identity, so they
-- cannot appear here. Payees outside the top 200 stay unkeyed downstream.
-- Published by export_us_sf_payees.py (index + one fiche per payee).
-- =============================================================================

WITH lines AS (
    SELECT payee_slug, payee_name, vendor, fiscal_year, vouchers_paid,
           is_non_profit, department, department_code
    FROM {{ ref('core_us_sf_vouchers') }}
    WHERE payee_slug IS NOT NULL AND vendor IS NOT NULL
),

by_variant AS (
    SELECT
        payee_slug,
        ANY_VALUE(payee_name)   AS payee_name,
        vendor,
        SUM(vouchers_paid)      AS total_usd,
        LOGICAL_OR(is_non_profit) AS is_non_profit
    FROM lines
    GROUP BY payee_slug, vendor
),

merge_reasons AS (
    SELECT vendor, ANY_VALUE(payee_merge_reason) AS merge_reason
    FROM {{ ref('core_us_sf_vouchers') }}
    WHERE payee_merge_reason IS NOT NULL
    GROUP BY vendor
),

-- years whose net is exactly zero are dropped (a refund cancelling a payment
-- is not activity) — first/last/n_years follow the kept years.
by_year AS (
    SELECT payee_slug, fiscal_year, SUM(vouchers_paid) AS usd
    FROM lines
    GROUP BY payee_slug, fiscal_year
    HAVING SUM(vouchers_paid) != 0
),

by_department AS (
    SELECT payee_slug, department, department_code, SUM(vouchers_paid) AS usd
    FROM lines
    WHERE department IS NOT NULL
    GROUP BY payee_slug, department, department_code
),

payee AS (
    SELECT
        v.payee_slug,
        ANY_VALUE(v.payee_name)                          AS name,
        SUM(v.total_usd)                                 AS total_paid_usd,
        LOGICAL_OR(v.is_non_profit)                      AS is_non_profit,
        COUNT(*)                                         AS n_variants,
        ARRAY_AGG(STRUCT(v.vendor AS name, ROUND(v.total_usd, 2) AS total, r.merge_reason)
                  ORDER BY v.total_usd DESC, v.vendor)   AS variants,
        -- first non-'other' manual bucket over the variants, by variant size
        ARRAY_AGG(b.bucket IGNORE NULLS ORDER BY IF(b.bucket = 'other', 1, 0), v.total_usd DESC LIMIT 1)[SAFE_OFFSET(0)]
                                                         AS bucket
    FROM by_variant v
    LEFT JOIN merge_reasons r USING (vendor)
    LEFT JOIN {{ ref('int_us_sf_payees') }} b USING (vendor)
    GROUP BY v.payee_slug
),

years AS (
    SELECT
        payee_slug,
        ARRAY_AGG(STRUCT(fiscal_year, ROUND(usd, 2) AS usd) ORDER BY fiscal_year) AS by_year,
        MIN(fiscal_year)   AS first_year,
        MAX(fiscal_year)   AS last_year,
        COUNT(*)           AS n_years
    FROM by_year
    GROUP BY payee_slug
),

departments AS (
    SELECT
        payee_slug,
        ARRAY_AGG(STRUCT(department, department_code, ROUND(usd, 2) AS usd)
                  ORDER BY usd DESC, department LIMIT 8) AS top_departments
    FROM by_department
    GROUP BY payee_slug
),

ranked AS (
    SELECT
        p.*,
        ROW_NUMBER() OVER (ORDER BY p.total_paid_usd DESC, p.payee_slug) AS rank_all_time
    FROM payee p
),

provenance AS (
    SELECT DISTINCT dataset_id, dataset_name, dataset_page_url, attribution, rows_updated_at
    FROM {{ ref('core_us_sf_source_catalog') }}
    WHERE source_id = 'sf_vouchers'
)

SELECT
    r.payee_slug                       AS slug,
    r.name,
    COALESCE(r.bucket, IF(r.is_non_profit, 'nonprofit', 'other')) AS kind,
    r.is_non_profit,
    ROUND(r.total_paid_usd, 2)         AS total_paid_usd,
    r.rank_all_time,
    y.n_years,
    y.first_year,
    y.last_year,
    y.by_year,
    d.top_departments,
    r.n_variants,
    r.variants,
    pr.dataset_id                      AS source_dataset_id,
    pr.dataset_name                    AS source_name,
    pr.dataset_page_url                AS source_url,
    pr.attribution                     AS source_attribution,
    pr.rows_updated_at                 AS source_rows_updated_at,
    'USD'                              AS unit
FROM ranked r
JOIN years y USING (payee_slug)
LEFT JOIN departments d USING (payee_slug)
CROSS JOIN provenance pr
WHERE r.rank_all_time <= 200
