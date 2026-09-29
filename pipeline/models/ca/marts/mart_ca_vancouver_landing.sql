-- =============================================================================
-- Mart: the hub page's headline figures — ONE ROW, every number beside its
-- provenance (source_url + rows_updated_at from the catalog), so the export
-- writes the ADR-0010 envelope from columns, not constants.
--
-- "latest complete year" for contracts = the last award_year that is not
-- the current calendar year (the current one is partial by construction).
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH cat AS (
    SELECT source_id, dataset_title, dataset_page_url, license_title, license_url, rows_updated_at
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
),

contracts AS (
    -- Awards only: the register is one row per BIDDER per competition, so
    -- COUNT(*) would count losing bids as contracts (it did, on 2026-09-12).
    SELECT
        COUNTIF(is_awarded)                                     AS n_contracts,
        -- a shared amount printed beside several winners counts once (core)
        SUM(IF(is_awarded, counted_amount_cad, NULL))           AS contracts_total_cad,
        COUNT(DISTINCT bid_number)                              AS n_competitions,
        COUNT(*)                                                AS n_responses,
        MIN(award_year)                                         AS contracts_first_year,
        MAX(award_year)                                         AS contracts_last_year,
        COUNT(DISTINCT IF(is_awarded, vendor_key, NULL))        AS n_vendors,
        COUNT(DISTINCT vendor_key)                              AS n_bidders
    FROM {{ ref('core_ca_vancouver_contracts') }}
),

contracts_latest AS (
    SELECT award_year, SUM(IF(is_awarded, counted_amount_cad, NULL)) AS total_cad, COUNTIF(is_awarded) AS n
    FROM {{ ref('core_ca_vancouver_contracts') }}
    WHERE award_year < EXTRACT(YEAR FROM CURRENT_DATE())
    GROUP BY award_year
    ORDER BY award_year DESC
    LIMIT 1
),

votes AS (
    SELECT
        COUNT(*)                                    AS n_votes_cast,
        COUNT(DISTINCT item_key)                    AS n_items,
        MIN(vote_date)                              AS votes_first_date,
        MAX(vote_date)                              AS votes_last_date,
        COUNTIF(is_opposition)                      AS n_opposition,
        COUNTIF(is_conflict)                        AS n_conflicts,
        COUNT(DISTINCT IF(is_rezoning, item_key, NULL)) AS n_rezoning_items
    FROM {{ ref('core_ca_vancouver_votes') }}
),

pay AS (
    SELECT
        MAX(fiscal_year)                            AS pay_latest_year,
        MIN(fiscal_year)                            AS pay_first_year
    FROM {{ ref('core_ca_vancouver_remuneration') }}
),

pay_latest AS (
    SELECT fiscal_year, COUNT(*) AS n_people, SUM(remuneration_cad) AS remuneration_total_cad
    FROM {{ ref('core_ca_vancouver_remuneration') }} r
    WHERE fiscal_year = (SELECT pay_latest_year FROM pay)
    GROUP BY fiscal_year
),

polys AS (
    SELECT COUNT(*) AS n_polygons, COUNTIF(NOT has_tax_coord) AS n_polygons_unkeyed
    FROM {{ ref('core_ca_vancouver_parcel_polygons') }}
),

parcels AS (
    SELECT
        COUNT(*)                                    AS n_parcels,
        COUNTIF(has_roll_row)                       AS n_parcels_with_roll,
        SUM(n_properties)                           AS n_properties,
        COUNTIF(year_built IS NOT NULL)             AS n_parcels_dated,
        MIN(year_built)                             AS oldest_year_built,
        SUM(land_value_cad)                         AS land_value_total_cad,
        SUM(tax_levy_cad)                           AS tax_levy_total_cad,
        ANY_VALUE(report_year)                      AS roll_year
    FROM {{ ref('core_ca_vancouver_parcels') }}
),

pop AS (
    SELECT population, census_year, source AS pop_source, source_url AS pop_source_url
    FROM {{ ref('core_ca_vancouver_population') }}
    ORDER BY census_year DESC LIMIT 1
)

SELECT
    'CAD' AS unit,
    -- contracts
    c.n_contracts, c.contracts_total_cad, c.n_competitions, c.n_responses, c.contracts_first_year, c.contracts_last_year, c.n_vendors, c.n_bidders,
    cl.award_year AS contracts_latest_year, cl.total_cad AS contracts_latest_total_cad, cl.n AS contracts_latest_n,
    (SELECT dataset_title FROM cat WHERE source_id = 'awarded_contracts')    AS contracts_source_name,
    (SELECT dataset_page_url FROM cat WHERE source_id = 'awarded_contracts') AS contracts_source_url,
    (SELECT license_title FROM cat WHERE source_id = 'awarded_contracts')    AS contracts_license,
    (SELECT rows_updated_at FROM cat WHERE source_id = 'awarded_contracts')  AS contracts_as_of,
    -- votes
    v.n_votes_cast, v.n_items, v.votes_first_date, v.votes_last_date, v.n_opposition, v.n_conflicts, v.n_rezoning_items,
    (SELECT dataset_title FROM cat WHERE source_id = 'council_voting_records')    AS votes_source_name,
    (SELECT dataset_page_url FROM cat WHERE source_id = 'council_voting_records') AS votes_source_url,
    (SELECT license_title FROM cat WHERE source_id = 'council_voting_records')    AS votes_license,
    (SELECT rows_updated_at FROM cat WHERE source_id = 'council_voting_records')  AS votes_as_of,
    -- payroll (aggregate only)
    p.pay_first_year, pl.fiscal_year AS pay_latest_year, pl.n_people AS pay_latest_n_people, pl.remuneration_total_cad AS pay_latest_total_cad,
    (SELECT dataset_title FROM cat WHERE source_id = 'employee_remuneration')    AS pay_source_name,
    (SELECT dataset_page_url FROM cat WHERE source_id = 'employee_remuneration') AS pay_source_url,
    (SELECT license_title FROM cat WHERE source_id = 'employee_remuneration')    AS pay_license,
    (SELECT rows_updated_at FROM cat WHERE source_id = 'employee_remuneration')  AS pay_as_of,
    -- fabric
    f.n_parcels, pg.n_polygons, pg.n_polygons_unkeyed, f.n_parcels_with_roll, f.n_properties, f.n_parcels_dated, f.oldest_year_built,
    f.land_value_total_cad, f.tax_levy_total_cad, f.roll_year,
    (SELECT dataset_title FROM cat WHERE source_id = 'property_parcel_polygons')    AS parcels_source_name,
    (SELECT dataset_page_url FROM cat WHERE source_id = 'property_parcel_polygons') AS parcels_source_url,
    (SELECT dataset_title FROM cat WHERE source_id = 'property_tax_report_2025')    AS roll_source_name,
    (SELECT dataset_page_url FROM cat WHERE source_id = 'property_tax_report_2025') AS roll_source_url,
    (SELECT license_title FROM cat WHERE source_id = 'property_tax_report_2025')    AS roll_license,
    (SELECT rows_updated_at FROM cat WHERE source_id = 'property_tax_report_2025')  AS roll_as_of,
    -- population
    po.population, po.census_year, po.pop_source, po.pop_source_url
FROM contracts c
CROSS JOIN contracts_latest cl
CROSS JOIN votes v
CROSS JOIN pay p
CROSS JOIN pay_latest pl
CROSS JOIN parcels f
CROSS JOIN polys pg
CROSS JOIN pop po
