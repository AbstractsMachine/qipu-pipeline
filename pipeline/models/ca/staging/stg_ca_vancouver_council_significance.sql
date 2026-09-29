-- =============================================================================
-- Staging: how much each council decision belongs in the story of the city
-- (derived source).
--
-- Source: raw.ca_vancouver_council_significance, written by
-- pipeline/scripts/ca_vancouver_city/reading/ingest_significance.py
-- (SIGNIFICANCE.md). One row per record scored: `sig` 0–100 and its kind —
-- event (a crisis met, something big hosted), stand (a position taken, a course
-- reversed, a reckoning), landmark (a known place born, saved, opened or lost),
-- rule (a rule everyone lives with), none. A second measure beside `interest`
-- (how much a decision changes how the city is run), never a replacement.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

SELECT
    id                                   AS record_key,
    SAFE_CAST(sig AS INT64)              AS significance,
    kind                                 AS significance_kind,
    sv                                   AS significance_version,
    model                                AS scored_by,
    SAFE_CAST(scored_at AS TIMESTAMP)    AS scored_at,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_council_significance') }}
