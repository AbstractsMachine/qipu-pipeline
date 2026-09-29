-- =============================================================================
-- Core: City places OBT — one row per place, tied to the map's units.
--
-- place_id: ca_org_key(name) — the URL slug ("fire-hall-no-8"); prefixed
-- with the kind when two kinds share a name ("park-…" / "community-centre-…"),
-- and suffixed with the published record id when a name repeats within a kind.
-- tax_coord: the parcel CONTAINING the place's point; when the point falls on
-- a street or lane, the nearest parcel within 25 m (rule 'nearest_25m');
-- otherwise NULL. Never farther: a place is not attached to a neighbour's lot.
-- block_idx: the city block containing the point (the map's clickable unit).
-- Parks join from core_ca_vancouver_parks: point = polygon centroid, no parcel.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

WITH p AS (
    SELECT place_kind, source_id, source_record_id, place_name, address, local_area, lon, lat, url, facts,
           ST_GEOGPOINT(lon, lat) AS pt
    FROM {{ ref('stg_ca_vancouver_places') }}
    WHERE place_name IS NOT NULL
    UNION ALL
    -- a park drawn as several polygons is one place (254 polygons, 253 parks)
    SELECT 'park', 'parks_polygons', park_name, park_name, CAST(NULL AS STRING), ANY_VALUE(local_area),
           ST_X(ST_CENTROID(ST_UNION_AGG(geog))), ST_Y(ST_CENTROID(ST_UNION_AGG(geog))), ANY_VALUE(park_url),
           TO_JSON_STRING(STRUCT(ANY_VALUE(classification) AS classification, SUM(area_ha) AS area_ha)), ST_CENTROID(ST_UNION_AGG(geog))
    FROM {{ ref('core_ca_vancouver_parks') }}
    WHERE park_name IS NOT NULL
    GROUP BY 3
),

in_parcel AS (
    SELECT p.source_id, p.source_record_id, ANY_VALUE(pc.tax_coord) AS tax_coord
    FROM p
    JOIN {{ ref('core_ca_vancouver_parcels') }} pc ON p.place_kind != 'park' AND p.pt IS NOT NULL AND ST_CONTAINS(pc.parcel_geog, p.pt)
    GROUP BY 1, 2
),

nearest AS (
    SELECT source_id, source_record_id, tax_coord
    FROM (
        SELECT p.source_id, p.source_record_id, pc.tax_coord,
               ROW_NUMBER() OVER (PARTITION BY p.source_id, p.source_record_id ORDER BY ST_DISTANCE(pc.parcel_geog, p.pt)) AS rn
        FROM p
        JOIN {{ ref('core_ca_vancouver_parcels') }} pc ON p.place_kind != 'park' AND p.pt IS NOT NULL AND ST_DWITHIN(pc.parcel_geog, p.pt, 25)
    )
    WHERE rn = 1
),

blk AS (
    SELECT p.source_id, p.source_record_id, ANY_VALUE(b.block_idx) AS block_idx, ANY_VALUE(b.local_area) AS block_local_area
    FROM p
    JOIN {{ ref('core_ca_vancouver_blocks') }} b ON p.pt IS NOT NULL AND ST_CONTAINS(b.geog, p.pt)
    GROUP BY 1, 2
),

keyed AS (
    SELECT p.*,
           {{ ca_org_key('p.place_name') }} AS name_key,
           COUNT(*) OVER (PARTITION BY p.place_kind, {{ ca_org_key('p.place_name') }}) AS n_same_name,
           COUNT(*) OVER (PARTITION BY {{ ca_org_key('p.place_name') }}) AS n_same_name_any_kind
    FROM p
)

SELECT
    CONCAT(IF(k.n_same_name_any_kind > 1, CONCAT(REPLACE(k.place_kind, '_', '-'), '-'), ''), k.name_key,
           IF(k.n_same_name > 1, CONCAT('-', REGEXP_REPLACE(LOWER(k.source_record_id), r'[^a-z0-9]+', '-')), '')) AS place_id,
    k.place_kind,
    k.source_id,
    k.source_record_id,
    k.place_name,
    k.address,
    COALESCE(k.local_area, bl.block_local_area)       AS local_area,
    k.lon,
    k.lat,
    k.url,
    k.facts,
    COALESCE(c.tax_coord, n.tax_coord)                AS tax_coord,
    CASE WHEN c.tax_coord IS NOT NULL THEN 'contains'
         WHEN n.tax_coord IS NOT NULL THEN 'nearest_25m' END AS parcel_rule,
    bl.block_idx
FROM keyed k
LEFT JOIN in_parcel c USING (source_id, source_record_id)
LEFT JOIN nearest n USING (source_id, source_record_id)
LEFT JOIN blk bl USING (source_id, source_record_id)
