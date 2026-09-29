-- =============================================================================
-- Mart: the map's council record — one row per item, with every parcel it is
-- placed on (centroid lon/lat, the block containing it, and the placement
-- rule), plus provenance. Read by
-- pipeline/scripts/ca_vancouver_city/build_record.py.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts', 'citymap']) }}

WITH cat AS (
    SELECT ARRAY_AGG(STRUCT(source_id, dataset_title AS name, dataset_page_url AS url,
                            license_title AS license, rows_updated_at AS as_of)) AS sources
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
    WHERE source_id IN ('council_voting_records', 'property_addresses', 'property_parcel_polygons')
),

places AS (
    SELECT
        pl.item_key,
        ARRAY_AGG(STRUCT(p.lon AS lon, p.lat AS lat, b.block_idx AS block_idx, pl.rule AS rule,
                         pl.civic_number AS civic_number, pl.std_street AS std_street)
                  ORDER BY pl.std_street, pl.civic_number) AS places
    FROM {{ ref('stg_ca_vancouver_council_item_places') }} pl
    JOIN {{ ref('core_ca_vancouver_parcels') }} p ON p.tax_coord = pl.tax_coord
    LEFT JOIN {{ ref('core_ca_vancouver_blocks') }} b ON ST_CONTAINS(b.geog, ST_GEOGPOINT(p.lon, p.lat))
    GROUP BY pl.item_key
)

SELECT i.*, COALESCE(pl.places, []) AS places, cat.sources,
       rd.plain_line, rd.interest, rd.record_type, rd.topic, rd.subtopic, rd.action AS read_action, rd.subjects AS read_subjects,
       yr.public_rank, yr.item_group,
       sg.significance, sg.significance_kind,
       vr.resolution_text, vr.minutes_doc
FROM {{ ref('core_ca_vancouver_council_items') }} i
LEFT JOIN places pl USING (item_key)
LEFT JOIN {{ ref('core_ca_vancouver_council_readings') }} rd ON rd.record_key = i.item_key
-- the public ranking (core_ca_vancouver_council_year_ranks): NULL where the ranking did not name the item
LEFT JOIN {{ ref('core_ca_vancouver_council_year_ranks') }} yr ON yr.record_key = i.item_key
-- the story of the city (core_ca_vancouver_council_significance): NULL where not scored
LEFT JOIN {{ ref('core_ca_vancouver_council_significance') }} sg ON sg.record_key = i.item_key
-- the minutes' own words for the vote (core_ca_vancouver_voting_resolutions): NULL where unmatched
LEFT JOIN {{ ref('core_ca_vancouver_voting_resolutions') }} vr ON vr.item_key = i.item_key
CROSS JOIN cat
