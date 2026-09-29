-- =============================================================================
-- Core: SF places — the reviewed place↔facility crosswalk joined to the
--       City Facilities registry (Block 6 lieux backbone)
--
-- Sources: stg_us_sf_place_facilities (reviewed seed crosswalk: which
--          facility_id(s) make up a place, which one is primary),
--          stg_us_sf_city_facilities (the registry: address, APN, size,
--          owner, coordinates — read live, the crosswalk's copies are only
--          identity evidence).
-- Grain:  place_slug × facility_id (a place is often a campus of buildings).
--
-- Every place mart (identity, permits on its parcels, DPW projects nearby)
-- starts from this table; geo is the ST_GEOGPOINT of the registry coordinates.
-- =============================================================================

WITH xwalk AS (
    SELECT * FROM {{ ref('stg_us_sf_place_facilities') }}
),

fac AS (
    SELECT
        facility_id, common_name, address, city, zip_code,
        block_lot, apn_block, apn_lot, owned_leased, is_city_owned,
        department_name, gross_sq_ft, latitude, longitude, supervisor_district
    FROM {{ ref('stg_us_sf_city_facilities') }}
)

SELECT
    x.place_slug,
    x.facility_id,
    x.is_primary,
    x.match_method,
    x.match_evidence,
    x.distance_m,
    f.common_name,
    f.address,
    f.city,
    f.zip_code,
    f.block_lot,
    f.apn_block,
    f.apn_lot,
    f.owned_leased,
    f.is_city_owned,
    f.department_name,
    f.gross_sq_ft,
    f.latitude,
    f.longitude,
    f.supervisor_district,
    CASE WHEN f.longitude IS NOT NULL AND f.latitude IS NOT NULL
         THEN ST_GEOGPOINT(f.longitude, f.latitude) END AS geo
FROM xwalk x
JOIN fac f USING (facility_id)
