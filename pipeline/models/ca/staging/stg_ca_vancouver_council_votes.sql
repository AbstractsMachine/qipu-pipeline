-- =============================================================================
-- Staging: council voting records — typed, one row per member × vote.
--
-- Source: raw.ca_vancouver_council_voting_records (ODS council-voting-records).
-- Grain:  vote_detail_id (one councillor's vote on one agenda item).
-- Fields verified live 2026-09-07: meeting_type, vote_date, vote_number,
-- agenda_description, vote_start_date_time, council_member, vote, decision,
-- vote_detail_id. `vote` vocabulary: In Favour / In Opposition / Absent /
-- Abstain / No Vote / Declared Conflict / Ineligible.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

SELECT
    SAFE_CAST(vote_detail_id AS STRING)               AS vote_detail_id,
    SAFE_CAST(meeting_id AS STRING)                   AS meeting_id,
    NULLIF(TRIM(SAFE_CAST(meeting_type AS STRING)), '')       AS meeting_type,
    SAFE_CAST(SAFE_CAST(vote_date AS STRING) AS DATE)         AS vote_date,
    SAFE_CAST(vote_number AS INT64)                   AS vote_number,
    NULLIF(TRIM(SAFE_CAST(agenda_description AS STRING)), '') AS agenda_description,
    SAFE_CAST(SAFE_CAST(vote_start_date_time AS STRING) AS TIMESTAMP) AS vote_started_at,
    NULLIF(TRIM(SAFE_CAST(council_member AS STRING)), '')     AS council_member,
    NULLIF(TRIM(SAFE_CAST(vote AS STRING)), '')               AS vote,
    NULLIF(TRIM(SAFE_CAST(decision AS STRING)), '')           AS decision,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_council_voting_records') }}
