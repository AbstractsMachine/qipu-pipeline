-- =============================================================================
-- Intermediate: curated "what a payment buys" lines with measured amounts
--
-- Sources: stg_us_sf_payee_materiality (the editorial seed only picks WHICH
--          vendor × department × sub_object × FY lines to feature + a label),
--          core_us_sf_vouchers (every dollar is summed from the vouchers).
-- Grain:  slug (one featured line). mart_us_sf_payee_materiality adds
--         provenance + execution status.
-- =============================================================================

WITH picks AS (
    SELECT * FROM {{ ref('stg_us_sf_payee_materiality') }}
),

amounts AS (
    SELECT
        p.slug,
        ANY_VALUE(v.object)   AS object,
        SUM(v.vouchers_paid)  AS amount_usd,
        COUNT(*)              AS n_voucher_lines
    FROM picks p
    INNER JOIN {{ ref('core_us_sf_vouchers') }} v
        ON  v.vendor      = p.vendor
        AND v.department  = p.department
        AND v.sub_object  = p.sub_object
        AND v.fiscal_year = p.fiscal_year
    GROUP BY p.slug
)

SELECT
    p.slug,
    p.label,
    p.editorial_note,
    p.vendor,
    p.department,
    a.object,
    p.sub_object,
    p.fiscal_year,
    a.amount_usd,
    a.n_voucher_lines,
    p.method,
    p.added_at
FROM picks p
INNER JOIN amounts a USING (slug)
