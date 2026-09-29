-- =============================================================================
-- Staging: the council record, read (derived source).
--
-- Source: raw.ca_vancouver_council_readings, written by
-- pipeline/scripts/ca_vancouver_city/reading/ingest_readings.py from the readers'
-- output (READING-COMPACT.md). One row per record id — a voting-record item_key or
-- a minutes motion_key. `held` rows failed a mechanical check (a name or number
-- not in the record, a flag the reader could not fix) and are kept but never
-- published; see held.jsonl beside the store.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

SELECT
    id                                        AS record_key,
    source,
    NULLIF(TRIM(line), '')                    AS plain_line,
    SAFE_CAST(score AS INT64)                 AS interest,
    band                                      AS interest_band,
    NULLIF(record_type, '')                   AS record_type,
    NULLIF(topic, '')                         AS topic,
    NULLIF(subtopic, '')                      AS subtopic,
    NULLIF(action, '')                        AS action,
    ARRAY(SELECT JSON_VALUE(s, '$') FROM UNNEST(JSON_QUERY_ARRAY(subjects)) s) AS subjects,
    ARRAY(SELECT JSON_VALUE(f, '$') FROM UNNEST(JSON_QUERY_ARRAY(flags)) f)    AS flags,
    SAFE_CAST(fixed AS BOOL)                  AS fixed,
    SAFE_CAST(held AS BOOL)                   AS is_held,
    held_why,
    rv                                        AS reading_version,
    model                                     AS read_by,
    SAFE_CAST(read_at AS TIMESTAMP)           AS read_at,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_council_readings') }}
