-- =============================================================================
-- Mart: one row per City place with everything linked to it
-- (core_ca_vancouver_place_links, rules written there):
--   council   items council voted on that name the place's parcel
--   permits   building permits issued on the parcel (type, value, date)
--   heritage  Heritage Register entries on the parcel
--   capital   capital programs naming the place, with their budget years
-- plus the parcel's assessment facts (year built, zoning) from the roll, and
-- the source dataset from the catalog. Kind-specific facts stay as published
-- JSON (`facts`).
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH l AS (SELECT * FROM {{ ref('core_ca_vancouver_place_links') }}),

council AS (
    SELECT l.place_id,
           ARRAY_AGG(STRUCT(ci.item_key, ci.vote_date, ci.title, ci.outcome_line, ci.is_contested, ci.n_in_favour, ci.n_opposition)
                     ORDER BY ci.vote_date DESC, ci.item_key LIMIT 60) AS council,
           COUNT(*) AS n_council
    FROM l JOIN {{ ref('core_ca_vancouver_council_items') }} ci ON l.link_kind = 'council_item' AND ci.item_key = l.link_id
    GROUP BY 1
),

permits AS (
    SELECT l.place_id,
           ARRAY_AGG(STRUCT(bp.permit_number, bp.issue_date, bp.type_of_work, bp.project_value_cad) ORDER BY bp.issue_date DESC, bp.permit_number LIMIT 60) AS permits,
           COUNT(*) AS n_permits,
           SUM(bp.project_value_cad) AS permits_value_cad
    FROM l JOIN {{ ref('core_ca_vancouver_building_permits') }} bp ON l.link_kind = 'permit' AND bp.permit_number = l.link_id
    GROUP BY 1
),

heritage AS (
    SELECT l.place_id,
           ARRAY_AGG(STRUCT(h.id, h.buildingnamespecifics AS building, h.category, h.evaluationgroup AS evaluation_group,
                            h.municipaldesignationm AS municipal_designation, h.status) ORDER BY h.id) AS heritage
    FROM l JOIN {{ source('ca_vancouver_raw', 'ca_vancouver_heritage_sites') }} h ON l.link_kind = 'heritage' AND h.id = l.link_id
    GROUP BY 1
),

capital AS (
    SELECT l.place_id,
           ARRAY_AGG(STRUCT(cp.program_key, cp.program_name, cp.first_year, cp.last_year,
                            cp.expenditure_budget_all_years_cad, cp.new_multi_year_all_years_cad) ORDER BY cp.last_year DESC, cp.program_name) AS capital,
           SUM(cp.new_multi_year_all_years_cad) AS capital_new_budgets_cad
    FROM l JOIN {{ ref('mart_ca_vancouver_capital_programs') }} cp ON l.link_kind = 'capital' AND cp.program_key = l.link_id
    GROUP BY 1
),

cat AS (
    SELECT source_id, dataset_title, dataset_page_url, license_title, rows_updated_at
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
)

SELECT
    p.place_id, p.place_kind, p.place_name, p.address, p.local_area, p.lon, p.lat, p.url, p.facts,
    p.tax_coord, p.parcel_rule, p.block_idx,
    pc.year_built, pc.zoning_district, pc.land_value_cad, pc.improvement_value_cad,
    pc.area_m2 AS parcel_area_m2, pc.n_properties AS parcel_n_properties,
    COALESCE(co.n_council, 0)  AS n_council,
    COALESCE(pe.n_permits, 0)  AS n_permits,
    pe.permits_value_cad,
    COALESCE(ARRAY_LENGTH(he.heritage), 0) AS n_heritage,
    COALESCE(ARRAY_LENGTH(ca.capital), 0)  AS n_capital,
    ca.capital_new_budgets_cad,
    COALESCE(co.council, [])  AS council,
    COALESCE(pe.permits, [])  AS permits,
    COALESCE(he.heritage, []) AS heritage,
    COALESCE(ca.capital, [])  AS capital,
    ct.dataset_title    AS source_name,
    ct.dataset_page_url AS source_url,
    ct.license_title    AS source_license,
    ct.rows_updated_at  AS source_rows_updated_at
FROM {{ ref('core_ca_vancouver_places') }} p
LEFT JOIN {{ ref('core_ca_vancouver_parcels') }} pc USING (tax_coord)
LEFT JOIN council co USING (place_id)
LEFT JOIN permits pe USING (place_id)
LEFT JOIN heritage he USING (place_id)
LEFT JOIN capital ca USING (place_id)
LEFT JOIN cat ct ON ct.source_id = p.source_id
