-- =============================================================================
-- Core: SF building permits — row-level OBT
--
-- Source: stg_us_sf_building_permits (typed view over the ~1.29M-row raw).
-- Grain:  permit_number (× revision line where present). block_lot is the
--         Assessor APN that joins to core_us_sf_places.
-- estimated / revised cost = the applicant's DECLARED construction value, not
-- city spend (mart_us_sf_place_capital labels it and never sums it with
-- contract paid or bond expended).
-- =============================================================================

SELECT *
FROM {{ ref('stg_us_sf_building_permits') }}
