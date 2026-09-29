-- =============================================================================
-- Mart: per-place facility identity (Block 6A lieux backbone)
--
-- Grain: one row per place_slug.
--
-- Rolls the reviewed place↔facility crosswalk up to the structured identity a
-- fiche shows: the PRIMARY building (nearest-to-seed, from the crosswalk) for
-- address/APN/size, plus campus aggregates (how many buildings, total sq ft,
-- owned vs leased) and the DISTINCT APN list — the key the Building Permits
-- join (6D) will use. Facility attributes are read LIVE from
-- core_us_sf_places (the registry is the source of truth; the seed
-- only fixes which facility_ids belong to the place).
--
-- Identity only — asserts no money. The APN list it exposes is what turns a
-- place into a parcel key for downstream structured money joins.
-- =============================================================================


WITH joined AS (
    SELECT
        place_slug,
        facility_id,
        is_primary,
        common_name,
        address,
        city,
        zip_code,
        block_lot,
        apn_block,
        apn_lot,
        owned_leased,
        is_city_owned,
        department_name,
        gross_sq_ft,
        latitude,
        longitude,
        supervisor_district
    FROM {{ ref('core_us_sf_places') }}
),

primary_facility AS (
    SELECT
        place_slug,
        ANY_VALUE(common_name)        AS primary_name,
        ANY_VALUE(address)            AS primary_address,
        ANY_VALUE(city)               AS primary_city,
        ANY_VALUE(zip_code)           AS primary_zip,
        ANY_VALUE(block_lot)          AS primary_block_lot,
        ANY_VALUE(department_name)    AS primary_department_name,
        ANY_VALUE(is_city_owned)      AS primary_is_city_owned,
        ANY_VALUE(gross_sq_ft)        AS primary_gross_sq_ft,
        ANY_VALUE(latitude)           AS primary_latitude,
        ANY_VALUE(longitude)          AS primary_longitude,
        ANY_VALUE(supervisor_district) AS supervisor_district
    FROM joined
    WHERE is_primary
    GROUP BY place_slug
),

agg AS (
    SELECT
        place_slug,
        COUNT(*)                                          AS n_facilities,
        SUM(gross_sq_ft)                                  AS total_gross_sq_ft,
        COUNTIF(is_city_owned)                            AS n_owned,
        COUNTIF(NOT is_city_owned)                        AS n_leased,
        ARRAY_AGG(DISTINCT block_lot IGNORE NULLS)        AS apn_list,
        ARRAY_AGG(STRUCT(facility_id, common_name, block_lot, gross_sq_ft, is_city_owned)
                  ORDER BY gross_sq_ft DESC)              AS facilities
    FROM joined
    GROUP BY place_slug
)

SELECT
    p.place_slug,
    p.primary_name,
    p.primary_address,
    p.primary_city,
    p.primary_zip,
    p.primary_block_lot,
    p.primary_department_name,
    p.primary_is_city_owned,
    p.primary_gross_sq_ft,
    p.primary_latitude,
    p.primary_longitude,
    p.supervisor_district,
    a.n_facilities,
    a.total_gross_sq_ft,
    a.n_owned,
    a.n_leased,
    a.apn_list,
    a.facilities
FROM primary_facility p
JOIN agg a USING (place_slug)
