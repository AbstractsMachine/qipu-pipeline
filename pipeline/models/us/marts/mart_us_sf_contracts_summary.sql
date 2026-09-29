-- =============================================================================
-- Mart: SF supplier contracts — ONE ROW PER CONTRACT (prime-dedupe grain)
--
-- Sources: core_us_sf_contracts (48,350 team-member rows),
--          int_us_sf_purchasing_authorities (display families seed),
--          core_us_sf_source_catalog (provenance).
-- Grain:  contract_no — 31,860 contracts with at least one prime row.
--
-- Dedupe rules (docs/us/block-studies/3-contracts.md, all query-verified):
--   * Money = SUM over PRIME rows per contract_no. 40 contracts carry two
--     prime rows whose amounts are ADDITIVE amendments (incl. negative
--     rows, e.g. 1000035538: $1,230,342.68 and −$824,329.58) — summing is
--     the correct netting. Summing ALL 48,350 rows would inflate agreed by
--     ~$8.1B of sub/JV rows (tests/us/assert_us_sf_contracts_summary_total).
--   * The 75 sub-only contracts (no prime row) are EXCLUDED — their rows
--     carry team-member attachments, not a contract-level award.
--   * consumed_amt NEVER enters this mart: measured garbage (one rec
--     center shows $83.35B consumed on a $140.3M award; citywide it sums
--     to $118.37B vs $93.06B agreed). The source's remaining column is
--     referenced ONLY inside src_arithmetic_consistent (a boolean that
--     says whether the source's own agreed = paid + remaining identity
--     holds) and is never carried as a value.
--   * "Remaining" = GREATEST(agreed − paid, 0) (remaining_calc_usd), always
--     displayed with the reconciliation flag.
--   * paid_usd is the source's pmt_amt = lifetime voucher payments
--     (spot-verified vs the voucher join at ±0.1%) — voucher sums are the
--     only contract money we publish. paid > agreed on ~1,053 contracts
--     (construction-heavy): payments accumulate across modifications while
--     agreed reflects the base document — a méthode note, not an error.
--
-- Flags:
--   * is_sole_source: sole_source_flg='X' on ANY row of the contract (the
--     flag sometimes lives on team rows; 1,314 of the register's 1,316
--     flagged contracts have a prime row and appear here).
--   * is_active: term_end >= today (America/Los_Angeles). NULL end dates
--     (370 contracts) are is_active=NULL — an explicit unknown bucket,
--     never counted as active. Placeholder 2200-12-31 dates were already
--     NULLed in stg (term_end_date_is_placeholder).
-- =============================================================================

WITH prime_rows AS (
    SELECT *
    FROM {{ ref('core_us_sf_contracts') }}
    WHERE is_prime_contractor_row
      AND contract_no IS NOT NULL
),

-- Flags can sit on sub/JV rows only — read them across ALL rows per contract.
all_row_flags AS (
    -- The source flags are 'X' or NULL (never 'N'): LOGICAL_OR over
    -- all-NULL comparisons returns NULL in BigQuery → COALESCE to FALSE.
    SELECT
        contract_no,
        COALESCE(LOGICAL_OR(sole_source_flg = 'X'), FALSE)  AS is_sole_source,
        COALESCE(LOGICAL_OR(non_profit = 'X'), FALSE)       AS is_non_profit
    FROM {{ ref('core_us_sf_contracts') }}
    WHERE contract_no IS NOT NULL
    GROUP BY contract_no
),

team_counts AS (
    SELECT
        contract_no,
        COUNTIF(project_team_constituent = 'Subcontractor')             AS n_subcontractor_rows,
        COUNTIF(project_team_constituent = 'Joint Venture Constituent') AS n_jv_rows
    FROM {{ ref('core_us_sf_contracts') }}
    WHERE contract_no IS NOT NULL
    GROUP BY contract_no
),

dedupe AS (
    SELECT
        contract_no,
        -- Dims: constant per contract in practice; MAX() prefers non-null
        -- when one of two prime rows is blank.
        MAX(contract_title)                 AS contract_title,
        MAX(contract_type)                  AS contract_type,
        MAX(purchasing_authority)           AS purchasing_authority,
        MAX(department_code)                AS department_code,
        MAX(department)                     AS department,
        MAX(prime_contractor)               AS prime_contractor,
        MIN(term_start_date)                AS term_start_date,
        MAX(term_end_date)                  AS term_end_date,
        LOGICAL_OR(term_end_date_is_placeholder) AS term_end_date_is_placeholder,
        COALESCE(LOGICAL_OR(project_team_lbe_status = 'LBE'), FALSE) AS is_lbe_prime,
        COUNT(*)                            AS n_prime_rows,
        -- Money (see header for why SUM over prime rows only)
        SUM(agreed_amt)                     AS agreed_usd,
        SUM(pmt_amt)                        AS paid_usd,
        -- Source self-consistency. The identity is FOUR-way, per the City's
        -- own data dictionary (cqi5-hm2d):
        --     Contract Awarded Amount
        --   = Purchase Orders Outstanding (consumed_amt)
        --   + Payments Made               (pmt_amt)
        --   + Remaining Contract Award    (remaining_amt)
        -- This held on 31,795 / 31,795 contracts when measured 2026-07-28.
        -- The previous test omitted consumed_amt and therefore "failed" on
        -- exactly the 20.2% of contracts with outstanding POs — which is
        -- where the false claim that the register contradicts itself came
        -- from. consumed_amt is referenced only inside this boolean and is
        -- never carried as a value (see header).
        COALESCE(
            ABS(SUM(agreed_amt) - SUM(consumed_amt) - SUM(pmt_amt) - SUM(remaining_amt))
                <= GREATEST(0.001 * ABS(SUM(agreed_amt)), 1.0),
            FALSE)                          AS src_arithmetic_consistent,
        MAX(data_as_of)                     AS data_as_of
    FROM prime_rows
    GROUP BY contract_no
),

provenance AS (
    SELECT DISTINCT
        dataset_id,
        dataset_name,
        dataset_page_url,
        attribution,
        rows_updated_at
    FROM {{ ref('core_us_sf_source_catalog') }}
    WHERE source_id = 'sf_supplier_contracts'
)

SELECT
    d.contract_no,
    d.contract_title,
    d.contract_type,
    d.purchasing_authority,
    COALESCE(fam.authority_family, 'legacy_none') AS authority_family,
    d.department_code,
    d.department,
    d.prime_contractor,
    d.term_start_date,
    d.term_end_date,
    d.term_end_date_is_placeholder,
    d.n_prime_rows,
    tc.n_subcontractor_rows,
    tc.n_jv_rows,
    d.agreed_usd,
    d.paid_usd,
    GREATEST(d.agreed_usd - d.paid_usd, 0)   AS remaining_calc_usd,
    d.src_arithmetic_consistent,
    d.paid_usd > d.agreed_usd                AS paid_exceeds_agreed,
    f.is_sole_source,
    f.is_non_profit,
    d.is_lbe_prime,
    -- Active today; NULL end = unknown bucket (never active)
    CASE
        WHEN d.term_end_date IS NULL THEN NULL
        ELSE d.term_end_date >= CURRENT_DATE('America/Los_Angeles')
    END                                       AS is_active,
    d.data_as_of,
    pr.dataset_id                             AS source_dataset_id,
    pr.dataset_name                           AS source_name,
    pr.dataset_page_url                       AS source_url,
    pr.attribution                            AS source_attribution,
    pr.rows_updated_at                        AS source_rows_updated_at,
    'USD'                                     AS unit
FROM dedupe d
INNER JOIN all_row_flags f USING (contract_no)
LEFT JOIN team_counts tc USING (contract_no)
LEFT JOIN {{ ref('int_us_sf_purchasing_authorities') }} fam
    ON fam.purchasing_authority = d.purchasing_authority
CROSS JOIN provenance pr
