-- =============================================================================
-- Mart: SF contract spend curves — vouchers paid per contract × fiscal year
--
-- Sources: core_us_sf_vouchers (8.07M distribution lines, contract_number
--          carried on $55.27B of lifetime payments),
--          mart_us_sf_contracts_summary (the contract register, prime grain),
--          core_us_sf_source_catalog (provenance).
-- Grain:  contract_no × fiscal_year, contracts present in the register only.
--
-- Join quality (docs/us/block-studies/3-contracts.md §6, query-verified):
-- 29,048 of 29,842 voucher contract numbers match the register — 97.3% of
-- numbers, 99.1% of joined dollars. Coverage starts FY2018 (PeopleSoft
-- migration: contract numbers change at the break — render the FY2018 note
-- on every curve). Spot-check: Alstom 1000006337 voucher sum $28.57M ≈ the
-- register's lifetime pmt_amt $28.6M.
--
-- execution_status (SF-BUILD-PLAN cross-cutting rule 2) replaces the
-- calendar boolean: SF fiscal year N ends June 30 of year N; the accounting
-- close then runs for months. Labeling rule used here (a display heuristic,
-- documented, not a claim about the Controller's process): in_progress
-- until June 30; recently_closed_preliminary for the 9 months after
-- year-end; closed afterwards.
-- =============================================================================

WITH register AS (
    SELECT contract_no
    FROM {{ ref('mart_us_sf_contracts_summary') }}
),

by_fy AS (
    SELECT
        v.contract_number                AS contract_no,
        v.fiscal_year,
        SUM(v.vouchers_paid)             AS vouchers_paid_usd,
        COUNT(DISTINCT v.voucher)        AS n_vouchers,
        COUNT(*)                         AS n_voucher_lines
    FROM {{ ref('core_us_sf_vouchers') }} v
    INNER JOIN register r
        ON v.contract_number = r.contract_no
    GROUP BY v.contract_number, v.fiscal_year
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
    b.contract_no,
    b.fiscal_year,
    b.vouchers_paid_usd,
    b.n_vouchers,
    b.n_voucher_lines,
    CASE
        WHEN CURRENT_DATE('America/Los_Angeles') <= DATE(b.fiscal_year, 6, 30)
            THEN 'in_progress'
        WHEN DATE_DIFF(CURRENT_DATE('America/Los_Angeles'),
                       DATE(b.fiscal_year, 6, 30), MONTH) < 9
            THEN 'recently_closed_preliminary'
        ELSE 'closed'
    END                                   AS execution_status,
    pr.dataset_id                         AS source_dataset_id,
    pr.dataset_name                       AS source_name,
    pr.dataset_page_url                   AS source_url,
    pr.attribution                        AS source_attribution,
    pr.rows_updated_at                    AS source_rows_updated_at,
    'USD'                                 AS unit
FROM by_fy b
CROSS JOIN provenance pr
