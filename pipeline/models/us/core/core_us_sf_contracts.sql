-- =============================================================================
-- Core: SF Supplier Contracts OBT — row-level contract × team-member rows
--
-- Source: stg_us_sf_contracts
-- Grain:  contract × project-team member (AS PUBLISHED — 48,350 rows for
--         31,935 distinct contract_no). Summing agreed_amt across rows
--         double-counts: consumers must either dedupe on contract_no or
--         filter is_prime_contractor_row. The grain fact is encoded as
--         tests/us/assert_us_sf_contracts_grain.sql.
-- =============================================================================

WITH contracts AS (
    SELECT *
    FROM {{ ref('stg_us_sf_contracts') }}
),

-- Editorial grouping of purchasing authorities — seed, display only.
authority_families AS (
    SELECT purchasing_authority, authority_family
    FROM {{ ref('stg_us_sf_purchasing_authority_families') }}
)

SELECT
    c.*,
    c.project_team_constituent = 'Prime Contractor'  AS is_prime_contractor_row
    ,
    fam.authority_family               AS purchasing_authority_family
FROM contracts c
LEFT JOIN authority_families fam
    ON fam.purchasing_authority = c.purchasing_authority
