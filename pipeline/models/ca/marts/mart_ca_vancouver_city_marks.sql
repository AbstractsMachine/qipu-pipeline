-- =============================================================================
-- Mart: the names the city map writes on its places — one row per mark.
-- Read by pipeline/scripts/ca_vancouver_city/build_marks.py -> base/marks.json
-- (the marks file the map's label overlay already reads).
--
-- TWO LANES, AS THE MAP DRAWS THEM:
--   designated  a Heritage Register building in the register's top tier
--               (evaluation_group 'A') that the City designated AND Canada or
--               British Columbia designated too. Written first and whatever its
--               size, as the map writes a city's designated landmarks.
--   named       the City's own registers of places — parks, community centres,
--               libraries, fire halls, cultural spaces (core_ca_vancouver_places)
--               — and every other tier-A Heritage Register building. Written
--               only when the thing is big enough on screen, so `span_m` is
--               required: a named place with no measured size is not shipped.
-- WHY THE FIRST LANE IS SO NARROW. The overlay writes that lane before the
-- local-area names, into the same collision grid. With all 127 City-designated
-- tier-A buildings in it — mostly houses spread across the residential areas —
-- the whole-city frame lost Arbutus Ridge, Fairview, Mount Pleasant and West
-- Point Grey to "Duty Master House" and "Residence - Crofton House" (measured on
-- the page, 2026-09-15). A city whose landmarks cluster downtown does not see this.
-- Left out on purpose: shelters (a label would point at people who use one)
-- and non-market housing (641 building names; the housing page lists them).
--
-- SPAN (how big the thing is — the map's label size ladder):
--   a building  max(sqrt(footprint area), its LiDAR median height), from the
--               2015 footprint containing the point, else the nearest within
--               20 m (span_rule says which)
--   a park      sqrt(the Park Board's published area)
-- YEAR: for a place from the City's registers, the 2025 roll's oldest standing
-- year_built on that footprint's parcel (core_ca_vancouver_buildings) — the
-- same year the map draws the building from, so the name arrives with it.
-- Heritage Register buildings carry NONE: the roll's year is the last major
-- rebuild for many of them (measured: Model School 1989, Abbott House 1998),
-- and a designated building must not vanish from the map before that year.
-- Parks carry none.
-- LABEL: the register's name with its printed abbreviations spelled out
-- ("Bldg." -> "Building"), a trailing street number dropped and the
-- non-breaking hyphen (U+2011, absent from the map's typeface) written as "-";
-- `site_name` keeps the name as printed. A name that is only an address
-- ("685 W Hastings") says nothing a street label does not, and is not shipped.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts', 'citymap']) }}

WITH heritage AS (
    SELECT
        CAST(heritage_id AS STRING) AS source_record_id,
        'heritage_sites'            AS source_id,
        site_name,
        is_municipal_designation AND (is_federal_designation OR is_provincial_designation) AS is_landmark,
        lon, lat
    FROM {{ ref('stg_ca_vancouver_heritage_sites') }}
    WHERE evaluation_group = 'A'
      AND category = 'HERITAGE BUILDINGS'
      AND site_name IS NOT NULL
      AND lon IS NOT NULL AND lat IS NOT NULL
),

places AS (
    SELECT source_record_id, source_id, place_name AS site_name, place_kind, lon, lat, facts
    FROM {{ ref('core_ca_vancouver_places') }}
    WHERE place_kind IN ('park', 'community_centre', 'library', 'fire_hall', 'cultural_space')
      AND lon IS NOT NULL AND lat IS NOT NULL
),

marks AS (
    SELECT
        IF(is_landmark, 'designated', 'named') AS mark_class,
        CAST(NULL AS STRING) AS kind,
        'heritage'           AS register_kind,
        source_id, source_record_id, site_name, lon, lat,
        CAST(NULL AS FLOAT64) AS park_area_m2
    FROM heritage
    UNION ALL
    SELECT
        'named',
        CASE place_kind
            WHEN 'park' THEN 'park'
            WHEN 'community_centre' THEN 'civic'
            WHEN 'library' THEN 'library'
            WHEN 'fire_hall' THEN 'fire'
            WHEN 'cultural_space' THEN 'arts'
        END,
        place_kind,
        source_id, source_record_id, site_name, lon, lat,
        IF(place_kind = 'park', SAFE_CAST(JSON_VALUE(facts, '$.area_ha') AS FLOAT64) * 10000, NULL)
    FROM places
),

buildings AS (
    SELECT footprint_id, geog, area_m2, IF(h_ok, h_p50_m, NULL) AS height_m, year_built
    FROM {{ ref('core_ca_vancouver_buildings') }}
),

on_footprint AS (
    SELECT m.source_id, m.source_record_id, b.footprint_id, b.area_m2, b.height_m, b.year_built,
           IF(ST_CONTAINS(b.geog, ST_GEOGPOINT(m.lon, m.lat)), 'contains', 'nearest_20m') AS span_rule,
           ROW_NUMBER() OVER (PARTITION BY m.source_id, m.source_record_id
                              ORDER BY ST_DISTANCE(b.geog, ST_GEOGPOINT(m.lon, m.lat)), b.area_m2 DESC) AS rn
    FROM marks m
    JOIN buildings b ON m.park_area_m2 IS NULL AND ST_DWITHIN(b.geog, ST_GEOGPOINT(m.lon, m.lat), 20)
),

cat AS (
    SELECT ARRAY_AGG(STRUCT(source_id, dataset_title AS name, dataset_page_url AS url,
                            license_title AS license, rows_updated_at AS as_of) ORDER BY source_id) AS sources
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
    WHERE source_id IN ('heritage_sites', 'parks_polygons', 'community_centres', 'libraries', 'fire_halls',
                        'cultural_spaces', 'building_footprints_2015', 'property_tax_report_2025')
)

SELECT
    m.mark_class,
    m.kind,
    m.register_kind,
    m.source_id,
    m.source_record_id,
    m.site_name,
    TRIM(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(
        REPLACE(m.site_name, '\u2011', '-'),
        r',\s*\d[\w\s-]*$', ''),          -- ", 315-321 W Cordova"
        r'\s+-\s*\d+$', ''),              -- " - 739"
        r'\bBldg\.', 'Building'),
        r'\bHse\.', 'House'),
        r'\bAssoc\.', 'Association'),
        r'\bBenev\.', 'Benevolent'))     AS label,
    m.lon,
    m.lat,
    CASE
        WHEN m.park_area_m2 IS NOT NULL THEN SQRT(m.park_area_m2)
        WHEN f.footprint_id IS NOT NULL THEN GREATEST(SQRT(f.area_m2), COALESCE(f.height_m, 0))
    END                                   AS span_m,
    IF(m.park_area_m2 IS NOT NULL, 'park_area', f.span_rule) AS span_rule,
    f.footprint_id,
    IF(m.park_area_m2 IS NULL AND m.register_kind != 'heritage', f.year_built, NULL) AS year_built,
    cat.sources
FROM marks m
LEFT JOIN on_footprint f ON f.source_id = m.source_id AND f.source_record_id = m.source_record_id AND f.rn = 1
CROSS JOIN cat
WHERE NOT REGEXP_CONTAINS(m.site_name, r'^\d')
  AND (m.mark_class = 'designated' OR m.park_area_m2 IS NOT NULL OR f.footprint_id IS NOT NULL)
