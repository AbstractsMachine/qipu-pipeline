-- =============================================================================
-- Staging: a voting-record decision's own words, from that day's minutes (derived source).
--
-- Source: raw.ca_vancouver_voting_resolutions (match_voting_resolutions.py). The
-- voting record prints only an agenda title; this is the item as the minutes
-- print it: the resolutions voted, with their amounts, and the outcome.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

SELECT
    item_key,
    SAFE_CAST(meeting_date AS DATE)       AS meeting_date,
    doc                                   AS minutes_doc,
    heading                               AS minutes_heading,
    NULLIF(TRIM(resolution_text), '')     AS resolution_text,
    SAFE_CAST(match_cover AS FLOAT64)     AS match_cover,
    SAFE_CAST(match_shared AS INT64)      AS match_shared,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_voting_resolutions') }}
