-- =============================================================================
-- Staging: council motions of the 1970s (derived source).
--
-- Source: raw.ca_vancouver_minutes_1970s_motions, written by
-- pipeline/scripts/ca_vancouver_city/parse_minutes_1970s.py from the Internet
-- Archive's OCR of the City's council minutes, 1970–1979 (CC0 or CC BY 3.0,
-- item by item — core carries each item's licence). One row per
-- motion as printed; `outcome` is NULL where no outcome was read, never assumed.
-- `meeting_date` is the date most of the page, the item's name and the Archive's
-- metadata agree on (`date_from` says which) — parse_minutes_1970s.meeting_date.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    identifier,
    SAFE_CAST(meeting_date AS DATE)    AS meeting_date,
    date_from,
    meeting_type,
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
    NULLIF(TRIM(duplicate_of), '')     AS duplicate_of,
    NULLIF(TRIM(duplicate_why), '')    AS duplicate_why,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_minutes_1970s_motions') }}
