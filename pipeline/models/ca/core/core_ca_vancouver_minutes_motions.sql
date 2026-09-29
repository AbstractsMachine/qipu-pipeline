-- =============================================================================
-- Core: COUNCIL MOTIONS FROM THE MINUTES — one row per motion, from two
-- collections read by the same rules (minutes_motions.py):
--
--   minutes_1970s    council's minutes 1970–1979, the Internet Archive's scans
--                    (CC0 or CC BY 3.0, item by item)
--   minutes_wayback  council's minutes 1995–2015 as the Wayback Machine saved
--                    council.vancouver.ca (the City's website; no open licence
--                    stated, so license_url is NULL)
--
--   motion_key   : <identifier>-<seq> | <meeting date>/<file>#<seq>, stable for as long as the parse is
--   source_url   : the scanned page, or the Wayback copy (#page=<n> for a PDF)
--   meeting_kind : "Regular Council", "Public Hearing", a standing committee… as the source names it
--   context      : what the minutes printed before the motion (letters, reports,
--                  delegations). It names people; it stays in this table and is
--                  not carried into the marts.
--
-- A MOTION PRINTED TWICE IS ONE MOTION. The parsers mark a row that repeats
-- another (`duplicate_of`: a meeting uploaded twice, a draft beside the final
-- minutes, a scan that holds its meeting twice — minutes_motions.repeated_motions)
-- and it is left out here; staging keeps every row as printed.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core', 'citymap']) }}

WITH seventies AS (
    SELECT
        CONCAT(m.identifier, '-', CAST(m.seq AS STRING))          AS motion_key,
        'minutes_1970s'                                            AS source,
        m.identifier                                               AS document_id,
        d.title                                                    AS document_title,
        m.meeting_date,
        CONCAT(m.meeting_type, ' Council')                         AS meeting_kind,
        m.seq, m.kind, m.leaf, m.section, m.heading,
        m.mover_printed, m.seconder_printed, m.mover, m.seconder,
        m.resolution, m.outcome, m.outcome_from, m.unanimous, m.opposed_printed, m.context,
        CONCAT(d.item_url, '/page/n', CAST(m.leaf AS STRING))      AS source_url,
        d.license_url,
        m._synced_at
    FROM {{ ref('stg_ca_vancouver_minutes_1970s_motions') }} m
    LEFT JOIN {{ ref('seed_ca_vancouver_minutes_1970s') }} d USING (identifier)
    WHERE m.duplicate_of IS NULL
),

wayback AS (
    SELECT
        CONCAT(w.doc_id, '#', CAST(w.seq AS STRING))              AS motion_key,
        'minutes_wayback'                                          AS source,
        w.doc_id                                                   AS document_id,
        w.original_url                                             AS document_title,
        w.meeting_date,
        w.meeting_kind,
        w.seq, w.kind, w.leaf, w.section, w.heading,
        w.mover_printed, w.seconder_printed, w.mover, w.seconder,
        w.resolution, w.outcome, w.outcome_from, w.unanimous, w.opposed_printed, w.context,
        w.source_url,
        CAST(NULL AS STRING)                                       AS license_url,
        w._synced_at
    FROM {{ ref('stg_ca_vancouver_minutes_wayback_motions') }} w
    WHERE w.duplicate_of IS NULL
)

SELECT u.*, EXTRACT(YEAR FROM u.meeting_date) AS meeting_year
FROM (SELECT * FROM seventies UNION ALL SELECT * FROM wayback) u
