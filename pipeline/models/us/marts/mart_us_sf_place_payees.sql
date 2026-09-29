-- =============================================================================
-- Mart: who got paid for work at a place (Block 6C — the payee chain)
--
-- Grain: one row per (place_slug, vendor).
--
-- place → its matched contracts (core_us_sf_place_contracts) → vouchers
-- (core_us_sf_vouchers on contract_number) → vendor + ACTUAL $ paid, with the
-- fiscal-year span. This is the "voucher/payee projects based in a location"
-- reconstruction: the real builders/operators paid on the place's contracts.
--
-- Money note: vouchers_paid is actual disbursement. It is the SAME money as the
-- contract `paid` and (for bond-funded work) the bond `expended` — a different
-- ledger view, never summed across sources (see mart_us_sf_place_capital).
-- =============================================================================

WITH place_contracts AS (
    SELECT DISTINCT place_slug, contract_no
    FROM {{ ref('core_us_sf_place_contracts') }}
),

voucher_lines AS (
    SELECT
        pc.place_slug,
        v.vendor,
        v.vouchers_paid,
        v.fiscal_year,
        v.contract_number
    FROM place_contracts pc
    JOIN {{ ref('core_us_sf_vouchers') }} v
      ON v.contract_number = pc.contract_no
    WHERE v.vendor IS NOT NULL
)

SELECT
    place_slug,
    vendor,
    SUM(vouchers_paid)                        AS paid_usd,
    COUNT(*)                                  AS n_lines,
    COUNT(DISTINCT contract_number)           AS n_contracts,
    MIN(fiscal_year)                          AS first_fiscal_year,
    MAX(fiscal_year)                          AS last_fiscal_year
FROM voucher_lines
GROUP BY place_slug, vendor
HAVING SUM(vouchers_paid) > 0
