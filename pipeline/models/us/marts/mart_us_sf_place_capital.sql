-- =============================================================================
-- Mart: capital & construction at a place (Block 6B+) — the UNIFIED, NO-SUM
-- capital model.
--
-- Grain: one row per (place_slug, source, item_key) — a distinct piece of
-- capital work at the place, from whichever ledger names it.
--
-- CRITICAL DOCTRINE (docs/us/block-studies/6-lieux.md §capital no-sum): the
-- capital ledgers are OVERLAPPING views of the same physical work —
--     GO bond `expended`  ⊇  contract `paid`  ≈  building-permit declared value
-- (a bond fund PAYS the contracts; the permit is the same job's declared cost).
-- So every row carries an explicit `amount_measure`, and totals are only ever
-- taken WITHIN one measure, NEVER summed across sources. The fiche groups by
-- source and labels each measure; it shows no cross-ledger grand total.
--
-- Sources wired so far:
--   bond_item    — GO bond program item that IS this place → amount_measure
--                  'bond_expended', amount = latest cumulative expended.
--   bond_project — named bond-funded project at the place → amount NULL
--                  (program-level $, shown as work, not an exact per-place total).
--   contract     — prime contract naming the place → amount_measure
--                  'contract_paid', amount = lifetime paid (voucher-derived).
-- (dpw / permit sources are added by later blocks against this same grain.)
-- =============================================================================

WITH bonds AS (
    SELECT
        place_slug,
        'bond'                                             AS source,
        source_kind,
        item_name                                          AS item_name,
        bond_program,
        component,
        voter_approved_date,
        CASE WHEN source_kind = 'bond_item' THEN expended_usd END        AS amount_usd,
        CASE WHEN source_kind = 'bond_item' THEN 'bond_expended' END     AS amount_measure,
        CASE WHEN source_kind = 'bond_item' THEN revised_budget_usd END  AS budget_usd,
        match_evidence,
        CAST(NULL AS STRING)                               AS contract_no,
        CAST(NULL AS STRING)                               AS status
    FROM {{ ref('core_us_sf_place_bonds') }}
),

contracts AS (
    SELECT
        place_slug,
        'contract'                                         AS source,
        'contract'                                         AS source_kind,
        contract_title                                     AS item_name,
        CAST(NULL AS STRING)                               AS bond_program,
        CAST(NULL AS STRING)                               AS component,
        CAST(NULL AS STRING)                               AS voter_approved_date,
        paid_usd                                           AS amount_usd,
        'contract_paid'                                    AS amount_measure,
        agreed_usd                                         AS budget_usd,
        match_evidence,
        contract_no,
        CAST(NULL AS STRING)                               AS status
    FROM {{ ref('core_us_sf_place_contracts') }}
),

unioned AS (
    SELECT * FROM bonds
    UNION ALL
    SELECT * FROM contracts
)

SELECT
    place_slug,
    source,
    source_kind,
    item_name,
    bond_program,
    component,
    voter_approved_date,
    amount_usd,
    amount_measure,
    budget_usd,
    contract_no,
    status,
    match_evidence
FROM unioned
