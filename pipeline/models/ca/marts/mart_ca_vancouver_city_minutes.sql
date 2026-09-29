-- =============================================================================
-- Mart: the map's council record from the MINUTES — one row per motion, from
-- the 1970s scans and the 1995–2015 Wayback copies (`source`), in the shape of
-- mart_ca_vancouver_city_council_items (item_key, vote_year, text, title,
-- outcome_line, subjects, places, sources) so the map's record builders read
-- both the same way, plus what only the minutes carry: the page, the kind of
-- motion and who moved it.
--
--   outcome_line : "Carried unanimously" | "Carried" | "Lost" | "Defeated" |
--                  "Not put" | NULL where the minutes' outcome was not read
--   is_contested : the minutes name at least one councillor opposed. The 1970s
--                  minutes only do from 1974; before that no motion is
--                  contested here, which says what the record prints, not how
--                  council voted.
--   page_url     : the scanned page, or the Wayback copy of the document
--   title        : the item's own heading when it names a subject; when it is
--                  a date, "Minutes of…" or a report's generic label
--                  ("Administrative Report", "City Manager's And Other Reports"),
--                  or there is none, the motion's own words ("A grant of $500 be
--                  approved to…"). Never the section: the map's year panel groups
--                  rows by title, and a section title put 45 unrelated 1975
--                  motions under one line.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts', 'citymap']) }}

WITH places AS (
    SELECT
        pl.motion_key,
        ARRAY_AGG(STRUCT(p.lon AS lon, p.lat AS lat, b.block_idx AS block_idx, pl.rule AS rule, pl.cited AS cited)
                  ORDER BY pl.rule, pl.tax_coord) AS places
    FROM {{ ref('stg_ca_vancouver_minutes_places') }} pl
    JOIN {{ ref('core_ca_vancouver_parcels') }} p ON p.tax_coord = pl.tax_coord
    LEFT JOIN {{ ref('core_ca_vancouver_blocks') }} b ON ST_CONTAINS(b.geog, ST_GEOGPOINT(p.lon, p.lat))
    GROUP BY 1
),

src AS (
    SELECT [
        STRUCT(
            'minutes_1970s' AS source_id,
            'City of Vancouver council meeting minutes, 1970–1979 (Internet Archive)' AS name,
            'https://archive.org/details/cityofvancouvercouncilminutes' AS url,
            -- two licences in this collection (CC0, and CC BY 3.0 on the CVAN_* items)
            (SELECT STRING_AGG(DISTINCT license_url, ' ; ' ORDER BY license_url) FROM {{ ref('seed_ca_vancouver_minutes_1970s') }}) AS license,
            (SELECT MAX(_synced_at) FROM {{ ref('core_ca_vancouver_minutes_motions') }} WHERE source = 'minutes_1970s') AS as_of),
        STRUCT(
            'minutes_wayback' AS source_id,
            'City of Vancouver council minutes, 1995–2015 (council.vancouver.ca, as saved by the Wayback Machine)' AS name,
            'https://web.archive.org/web/*/council.vancouver.ca/*' AS url,
            CAST(NULL AS STRING) AS license,
            (SELECT MAX(_synced_at) FROM {{ ref('core_ca_vancouver_minutes_motions') }} WHERE source = 'minutes_wayback') AS as_of)
    ] AS sources
)

SELECT
    m.motion_key                                     AS item_key,
    m.source,
    m.meeting_date                                   AS vote_date,
    m.meeting_year                                   AS vote_year,
    m.meeting_kind                                   AS meeting_type,
    m.resolution                                     AS text,
    CASE
        WHEN m.heading IS NOT NULL
         AND NOT REGEXP_CONTAINS(m.heading, r'^(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d')
         AND NOT REGEXP_CONTAINS(LOWER(m.heading), r'^(?:minutes of|adoption of minutes|(?:administrative|policy|city manager.?s?(?: and other)?|manager.?s?|standing committee|committee of the whole)\s+reports?\b)')
         -- a meeting's or a section's own name is not a subject ("Regular Council", "ADJOURNMENT")
         AND NOT REGEXP_CONTAINS(LOWER(m.heading), r'^(?:regular|special|inaugural) council$|^public hearing$|^adjournment$|^committee of the whole$|^in camera')
         AND m.heading != UPPER(m.heading)
        THEN RTRIM(m.heading, ' ,;:-')   -- "N.E. Corner of Kingsway & Nanaimo Street," loses its comma
        ELSE CONCAT(
            UPPER(SUBSTR(REGEXP_REPLACE(m.resolution, r'^\s*THAT\s+', ''), 1, 1)),
            SUBSTR(REGEXP_EXTRACT(REGEXP_REPLACE(m.resolution, r'^\s*THAT\s+', ''), r'^(.{1,110}\S)(?:\s|$)'), 2),
            IF(LENGTH(REGEXP_REPLACE(m.resolution, r'^\s*THAT\s+', '')) > 111, '…', ''))
    END                                              AS title,
    CASE m.outcome
        WHEN 'carried'  THEN IF(m.unanimous, 'Carried unanimously', 'Carried')
        WHEN 'lost'     THEN 'Lost'
        WHEN 'defeated' THEN 'Defeated'
        WHEN 'not put'  THEN 'Not put'
    END                                              AS outcome_line,
    m.opposed_printed IS NOT NULL                    AS is_contested,
    {{ ca_vancouver_subject_flags("CONCAT(COALESCE(m.heading, ''), ' ', COALESCE(m.resolution, ''))") }},
    m.kind,
    m.mover,
    m.seconder,
    m.unanimous,
    m.opposed_printed,
    m.document_id,
    m.seq,
    m.leaf,
    m.source_url                                     AS page_url,
    m.license_url,
    COALESCE(pl.places, [])                          AS places,
    src.sources,
    -- the reading (core_ca_vancouver_council_readings): NULL where not read or held
    rd.plain_line,
    rd.interest,
    rd.record_type,
    rd.topic,
    rd.subtopic,
    rd.action                                        AS read_action,
    rd.subjects                                      AS read_subjects,
    -- the public ranking (core_ca_vancouver_council_year_ranks): NULL where not named
    yr.public_rank,
    yr.item_group,
    -- the story of the city (core_ca_vancouver_council_significance): NULL where not scored
    sg.significance,
    sg.significance_kind
FROM {{ ref('core_ca_vancouver_minutes_motions') }} m
LEFT JOIN places pl USING (motion_key)
LEFT JOIN {{ ref('core_ca_vancouver_council_readings') }} rd ON rd.record_key = m.motion_key
LEFT JOIN {{ ref('core_ca_vancouver_council_year_ranks') }} yr ON yr.record_key = m.motion_key
LEFT JOIN {{ ref('core_ca_vancouver_council_significance') }} sg ON sg.record_key = m.motion_key
CROSS JOIN src
WHERE m.meeting_year IS NOT NULL
  -- from the voting record's first vote, a decision is the voting record's: the
  -- minutes stop the day before, so no decision is on the map twice
  AND m.meeting_date < (SELECT MIN(vote_date) FROM {{ ref('core_ca_vancouver_council_items') }})
