-- =============================================================================
-- Core: place ↔ GO-bond links (Block 6B)
--
-- Source: stg_us_sf_place_bonds (reviewed seed: bond_item rows carry the
--         place's exact bond $ — latest cumulative expended — and bond_project
--         rows name bond-funded work at program level).
-- Grain:  place_slug × source_kind × item_name.
-- =============================================================================

SELECT *
FROM {{ ref('stg_us_sf_place_bonds') }}
