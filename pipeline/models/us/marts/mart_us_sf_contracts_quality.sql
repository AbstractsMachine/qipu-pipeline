-- =============================================================================
-- Mart: SF contracts register — data-quality figures for the méthode block
--
-- Sources: core_us_sf_contracts, core_us_sf_vouchers, mart_us_sf_contracts_summary.
-- Grain:   one row.
--
-- n_sub_only                : contract numbers that appear only on sub-
--                             contractor rows (no prime row → excluded from
--                             the money perimeter).
-- voucher_contract_numbers  : distinct contract_number values on vouchers.
-- matched_in_register       : of those, how many exist in the prime register.
-- matched_dollar_share      : share of voucher $ (with a contract number) that
--                             lands on a registered contract.
-- These were computed by export_us_sf_contracts.py on the cores (E4); no
-- money is published from this table, only coverage counts/shares.
-- =============================================================================

WITH core_subonly AS (
    SELECT COUNT(DISTINCT c.contract_no) AS n_sub_only
    FROM {{ ref('core_us_sf_contracts') }} c
    WHERE c.contract_no IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM {{ ref('core_us_sf_contracts') }} p
        WHERE p.contract_no = c.contract_no AND p.is_prime_contractor_row)
),

v AS (
    SELECT contract_number, SUM(vouchers_paid) AS paid
    FROM {{ ref('core_us_sf_vouchers') }}
    WHERE contract_number IS NOT NULL
    GROUP BY contract_number
),

reg AS (
    SELECT contract_no FROM {{ ref('mart_us_sf_contracts_summary') }}
),

join_cov AS (
    SELECT
        COUNT(*)                                             AS voucher_contract_numbers,
        COUNTIF(r.contract_no IS NOT NULL)                   AS matched_in_register,
        SAFE_DIVIDE(SUM(IF(r.contract_no IS NOT NULL, v.paid, 0)), SUM(v.paid))
                                                             AS matched_dollar_share
    FROM v LEFT JOIN reg r ON v.contract_number = r.contract_no
)

SELECT
    s.n_sub_only,
    j.voucher_contract_numbers,
    j.matched_in_register,
    j.matched_dollar_share
FROM core_subonly s
CROSS JOIN join_cov j
