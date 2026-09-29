-- =============================================================================
-- Staging: City places, one shape — the facilities the City runs or funds,
-- from six portal datasets:
--   library            libraries (VPL branches)
--   community_centre   community-centres
--   fire_hall          fire-halls ("No 1" → "Fire Hall No 1")
--   shelter            homeless-shelter-locations
--   cultural_space     cultural-spaces, ACTIVE spaces owned by the City or the
--                      Park Board, as of the inventory's latest year
--   non_market_housing non-market-housing (buildings; 19 without a point)
-- Parks come from core_ca_vancouver_parks (polygons) in core. Kind-specific
-- facts travel in `facts` (JSON) exactly as published. Geometry: the portal's
-- GeoJSON Feature or geo_point_2d.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

WITH cs_year AS (
    SELECT MAX(SAFE_CAST(year AS INT64)) AS y FROM {{ source('ca_vancouver_raw', 'ca_vancouver_cultural_spaces') }}
)

SELECT 'library' AS place_kind, 'libraries' AS source_id, name AS source_record_id,
       IF(name IN ('Central Branch', 'Outreach Services'), CONCAT('Vancouver Public Library — ', name), CONCAT(name, ' Branch Library')) AS place_name,
       address, geo_local_area AS local_area,
       SAFE_CAST(JSON_VALUE(geo_point_2d, '$.lon') AS FLOAT64) AS lon, SAFE_CAST(JSON_VALUE(geo_point_2d, '$.lat') AS FLOAT64) AS lat,
       urllink AS url, CAST(NULL AS STRING) AS facts
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_libraries') }}
UNION ALL
SELECT 'community_centre', 'community_centres', name,
       IF(REGEXP_CONTAINS(LOWER(name), r'cent(re|er)'), name, CONCAT(name, ' Community Centre')),
       address, geo_local_area,
       SAFE_CAST(JSON_VALUE(geo_point_2d, '$.lon') AS FLOAT64), SAFE_CAST(JSON_VALUE(geo_point_2d, '$.lat') AS FLOAT64),
       urllink, NULL
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_community_centres') }}
UNION ALL
SELECT 'fire_hall', 'fire_halls', name, CONCAT('Fire Hall ', name),
       address, geo_local_area,
       SAFE_CAST(JSON_VALUE(geo_point_2d, '$.lon') AS FLOAT64), SAFE_CAST(JSON_VALUE(geo_point_2d, '$.lat') AS FLOAT64),
       NULL, NULL
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_fire_halls') }}
UNION ALL
SELECT 'shelter', 'homeless_shelter_locations', facility, facility,
       CAST(NULL AS STRING), geo_local_area,
       SAFE_CAST(JSON_VALUE(geo_point_2d, '$.lon') AS FLOAT64), SAFE_CAST(JSON_VALUE(geo_point_2d, '$.lat') AS FLOAT64),
       NULL, TO_JSON_STRING(STRUCT(category AS clientele, meals, pets, carts))
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_homeless_shelter_locations') }}
UNION ALL
SELECT 'cultural_space', 'cultural_spaces', CONCAT(cultural_space_name, ' | ', COALESCE(address, '')), cultural_space_name,
       address, local_area,
       SAFE_CAST(JSON_VALUE(geo_point_2d, '$.lon') AS FLOAT64), SAFE_CAST(JSON_VALUE(geo_point_2d, '$.lat') AS FLOAT64),
       website, TO_JSON_STRING(STRUCT(type, primary_use, ownership, square_feet, number_of_seats, year AS inventory_year))
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_cultural_spaces') }}, cs_year
WHERE SAFE_CAST(year AS INT64) = cs_year.y AND active_space = 'Yes'
  AND ownership IN ('City of Vancouver', 'Vancouver Park Board/COV')
UNION ALL
SELECT 'non_market_housing', 'non_market_housing', CAST(index_number AS STRING), COALESCE(NULLIF(TRIM(name), ''), address),
       address, CAST(NULL AS STRING),
       SAFE_CAST(JSON_VALUE(geom, '$.geometry.coordinates[0]') AS FLOAT64), SAFE_CAST(JSON_VALUE(geom, '$.geometry.coordinates[1]') AS FLOAT64),
       url,
       TO_JSON_STRING(STRUCT(
           project_status, SAFE_CAST(occupancy_year AS INT64) AS occupancy_year, operator,
           clientele_families, clientele_seniors, clientele_other,
           CAST(COALESCE(design_standard_studio, 0) + COALESCE(design_accessible_studio, 0) AS INT64) AS units_studio,
           CAST(COALESCE(design_standard_room, 0) + COALESCE(design_accessible_room, 0) AS INT64) AS units_room,
           CAST(COALESCE(design_standard_1br, 0) + COALESCE(design_accessible_1br, 0) + COALESCE(design_adaptable_1br, 0) AS INT64) AS units_1br,
           CAST(COALESCE(design_standard_2br, 0) + COALESCE(design_accessible_2br, 0) + COALESCE(design_adaptable_2br, 0) AS INT64) AS units_2br,
           CAST(COALESCE(design_standard_3br, 0) + COALESCE(design_accessible_3br, 0) + COALESCE(design_adaptable_3br, 0) AS INT64) AS units_3br,
           CAST(COALESCE(design_standard_4br, 0) + COALESCE(design_accessible_4br, 0) + COALESCE(design_adaptable_4br, 0) AS INT64) AS units_4br,
           CAST(COALESCE(design_accessible_studio, 0) + COALESCE(design_accessible_room, 0) + COALESCE(design_accessible_1br, 0) + COALESCE(design_accessible_2br, 0) + COALESCE(design_accessible_3br, 0) + COALESCE(design_accessible_4br, 0) AS INT64) AS units_accessible
       ))
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_non_market_housing') }}
