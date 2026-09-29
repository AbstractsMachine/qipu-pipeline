-- =============================================================================
-- Staging: council motions, 1995–2015 (derived source).
--
-- Source: raw.ca_vancouver_minutes_wayback_motions, written by
-- pipeline/scripts/ca_vancouver_city/parse_minutes_wayback.py from the City's
-- council minutes as the Wayback Machine saved council.vancouver.ca. One row per
-- motion as printed, read by the same rules as the 1970s (minutes_motions.py);
-- `outcome` is NULL where no outcome was read, never assumed.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    doc_id,
    SAFE_CAST(meeting_date AS DATE)    AS meeting_date,
    NULLIF(TRIM(meeting_kind), '')     AS meeting_kind,
    SAFE_CAST(seq AS INT64)            AS seq,
    kind,
    SAFE_CAST(leaf AS INT64)           AS leaf,
    NULLIF(TRIM(section), '')          AS section,
    NULLIF(TRIM(heading), '')          AS heading,
    mover_printed,
    seconder_printed,
    mover,
    seconder,
    NULLIF(TRIM(resolution), '')       AS resolution,
    outcome,
    outcome_from,
    SAFE_CAST(unanimous AS BOOL)       AS unanimous,
    opposed_printed,
    context,
    source_url,
    wayback_timestamp,
    original_url,
    NULLIF(TRIM(duplicate_of), '')     AS duplicate_of,
    NULLIF(TRIM(duplicate_why), '')    AS duplicate_why,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_minutes_wayback_motions') }}
