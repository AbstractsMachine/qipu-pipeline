-- =============================================================================
-- Core: what each place is linked to, one row per place × linked record.
--
-- link_kind and the rule that makes each link — nothing fuzzy, every rule
-- written here and printed on the place page:
--   council_item  a council item placed on the place's parcel
--                 (stg_ca_vancouver_council_item_places.tax_coord =
--                 core_ca_vancouver_places.tax_coord)
--   permit        an issued building permit whose point lies in that parcel
--   heritage      a Heritage Register site whose point lies in that parcel
--   capital       a capital budget program whose NAME names the place:
--                   library          "<branch> library" or "<branch> branch"
--                                    ("Central Branch": "central library" or
--                                    "library square")
--                   community_centre "<name> community centre/center"
--                   fire_hall        "fire hall/firehall/FH" + its number
--                                    ("#8", "No. 12", "FH#9"), not "theatre"
--                 compared letters-only, so "Marpole-Oakridge" and "RayCam"
--                 match their programs. Parks, shelters, cultural spaces and
--                 housing get no capital link: their names are not written
--                 into program names in a form a rule can bind.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

WITH pl AS (
    SELECT place_id, place_kind, source_record_id, place_name, tax_coord,
           REGEXP_REPLACE(LOWER(source_record_id), r'[^a-z]', '') AS rec_letters
    FROM {{ ref('core_ca_vancouver_places') }}
),

parcel AS (
    SELECT pl.place_id, pc.parcel_geog
    FROM pl
    JOIN {{ ref('core_ca_vancouver_parcels') }} pc USING (tax_coord)
),

council AS (
    SELECT DISTINCT pl.place_id, 'council_item' AS link_kind, cp.item_key AS link_id, 'same_parcel' AS rule
    FROM pl
    JOIN {{ ref('stg_ca_vancouver_council_item_places') }} cp ON cp.tax_coord = pl.tax_coord
),

permits AS (
    SELECT DISTINCT pa.place_id, 'permit', bp.permit_number, 'point_in_parcel'
    FROM parcel pa
    JOIN {{ ref('core_ca_vancouver_building_permits') }} bp
      ON bp.lon IS NOT NULL AND ST_CONTAINS(pa.parcel_geog, ST_GEOGPOINT(bp.lon, bp.lat))
),

heritage AS (
    SELECT DISTINCT pa.place_id, 'heritage', h.id, 'point_in_parcel'
    FROM parcel pa
    JOIN {{ source('ca_vancouver_raw', 'ca_vancouver_heritage_sites') }} h
      ON ST_CONTAINS(pa.parcel_geog, ST_GEOGPOINT(SAFE_CAST(JSON_VALUE(h.geo_point_2d, '$.lon') AS FLOAT64),
                                                  SAFE_CAST(JSON_VALUE(h.geo_point_2d, '$.lat') AS FLOAT64)))
),

programs AS (
    SELECT DISTINCT program_key, program_name,
           REGEXP_REPLACE(LOWER(program_name), r'[^a-z]', '') AS letters,
           LOWER(program_name) AS lower_name
    FROM {{ ref('core_ca_vancouver_capital_budget_lines') }}
    WHERE program_key != ''
),

capital AS (
    SELECT DISTINCT pl.place_id, 'capital', pr.program_key, CONCAT('name:', pl.place_kind)
    FROM pl
    JOIN programs pr ON
        (pl.place_kind = 'library' AND (
            (pl.source_record_id = 'Central Branch' AND (STRPOS(pr.letters, 'centrallibrary') > 0 OR STRPOS(pr.letters, 'librarysquare') > 0))
            OR (pl.source_record_id NOT IN ('Central Branch', 'Outreach Services')
                AND (STRPOS(pr.letters, CONCAT(pl.rec_letters, 'library')) > 0 OR STRPOS(pr.letters, CONCAT(pl.rec_letters, 'branch')) > 0))))
        OR (pl.place_kind = 'community_centre'
            AND STRPOS(pr.letters, CONCAT(REGEXP_REPLACE(pl.rec_letters, r'(cooperative|community|centre|center)', ''), 'communitycent')) > 0)
        OR (pl.place_kind = 'fire_hall' AND NOT REGEXP_CONTAINS(pr.lower_name, r'theat')
            AND REGEXP_CONTAINS(pr.lower_name, CONCAT(r'(fire ?hall|fh)\s*(no\.?\s*|#)?\s*', REGEXP_EXTRACT(pl.source_record_id, r'\d+'), r'\b')))
)

SELECT * FROM council
UNION ALL SELECT * FROM permits
UNION ALL SELECT * FROM heritage
UNION ALL SELECT * FROM capital
