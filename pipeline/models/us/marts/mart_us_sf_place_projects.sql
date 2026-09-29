-- =============================================================================
-- Mart: current & recent DPW projects on/near a place (Block 6C — spatial view)
--
-- Grain: one row per (place_slug, project_name) — the nearest point of each
-- distinct DPW project to any of the place's facility points.
--
-- The STRUCTURED spatial join: the place's facility coordinates
-- (core_us_sf_places via the crosswalk) → DPW project points within
-- PROXIMITY_M (ST_DWITHIN). DPW is SF's geolocated chantiers feed; this is the
-- "construction physically on/near this place" view. Carries NO money of its
-- own (client_contract_id bridges to a contract's $ where present) — an
-- activity list, never summed into a place total. Pre-Planning + Active +
-- recent are the useful states; ancient completed noise is dropped by requiring
-- a project_status and a non-null geometry.
--
-- Proximity is deliberately tight (120 m) — a facility centroid within 120 m of
-- a project point means the chantier is at/adjacent to the parcel, not merely
-- in the neighborhood. Honestly labeled "on or near this place" downstream.
-- =============================================================================

{% set proximity_m = 120 %}

WITH fac AS (
    SELECT
        x.place_slug,
        x.facility_id,
        f.geo
    FROM {{ ref('core_us_sf_places') }} x
    CROSS JOIN UNNEST([STRUCT(x.geo AS geo)]) AS f
    WHERE x.geo IS NOT NULL
),

proj AS (
    SELECT project_name, project_status, project_phase, facility_type,
           description, on_street, client_contract_id, start_date, end_date, geo
    FROM {{ ref('core_us_sf_dpw_projects') }}
    WHERE geo IS NOT NULL AND project_name IS NOT NULL AND project_status IS NOT NULL
),

matched AS (
    SELECT
        fac.place_slug,
        proj.project_name,
        proj.project_status,
        proj.project_phase,
        proj.facility_type,
        proj.description,
        proj.on_street,
        proj.client_contract_id,
        proj.start_date,
        proj.end_date,
        ST_DISTANCE(fac.geo, proj.geo) AS distance_m,
        ROW_NUMBER() OVER (
            PARTITION BY fac.place_slug, proj.project_name
            ORDER BY ST_DISTANCE(fac.geo, proj.geo), fac.facility_id
        ) AS rn
    FROM fac
    JOIN proj
      ON ST_DWITHIN(fac.geo, proj.geo, {{ proximity_m }})
)

SELECT
    place_slug,
    project_name,
    project_status,
    project_phase,
    facility_type,
    description,
    on_street,
    client_contract_id,
    start_date,
    end_date,
    ROUND(distance_m, 0) AS distance_m
FROM matched
WHERE rn = 1
