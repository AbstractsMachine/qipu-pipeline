-- =============================================================================
-- Mart: SF contract project teams — who is on each contract, in what role
--
-- Sources: core_us_sf_contracts, core_us_sf_source_catalog (provenance).
-- Grain:  contract_no × supplier × role × LBE status (amendment rows for
--         the same member are netted by the SUM, like the prime dedupe).
--
-- NEVER UNION THIS INTO CONTRACT MONEY (docs/us/block-studies/3-contracts.md
-- §4): attached_usd on non-prime rows lives in the PRIME's envelope — on
-- 486 of 2,171 contracts with named subs the sub total even exceeds the
-- prime agreed (reconciliation gap in the source). Team rows feed the fiche
-- "project team" tab and the LBE participation aggregates, both rendered as
-- their own labeled perimeter. Register money comes exclusively from
-- mart_us_sf_contracts_summary.
--
-- Roles as published: Prime Contractor / Subcontractor / Joint Venture
-- Constituent. LBE participation beyond primes = Subcontractor + JV rows
-- with LBE status (7,801 rows on 1,921 contracts, $3.15B attached).
-- =============================================================================

WITH members AS (
    SELECT
        contract_no,
        project_team_supplier                       AS supplier,
        project_team_constituent                    AS role,
        COALESCE(project_team_lbe_status = 'LBE', FALSE) AS is_lbe,
        SUM(agreed_amt)                             AS attached_usd,
        COUNT(*)                                    AS n_rows
    FROM {{ ref('core_us_sf_contracts') }}
    WHERE contract_no IS NOT NULL
      AND project_team_constituent IS NOT NULL
    GROUP BY contract_no, supplier, role, is_lbe
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
    m.contract_no,
    m.supplier,
    m.role,
    m.is_lbe,
    m.attached_usd,
    m.n_rows,
    pr.dataset_id                         AS source_dataset_id,
    pr.dataset_name                       AS source_name,
    pr.dataset_page_url                   AS source_url,
    pr.attribution                        AS source_attribution,
    pr.rows_updated_at                    AS source_rows_updated_at,
    'USD'                                 AS unit
FROM members m
CROSS JOIN provenance pr
