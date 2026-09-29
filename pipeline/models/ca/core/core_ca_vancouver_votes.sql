-- =============================================================================
-- Core: council votes OBT — one row per councillor × agenda item vote.
--
-- Adds the derived flags every mart reads (is_opposition, is_conflict,
-- is_rezoning) and a stable item key so "how many members opposed item X"
-- is a GROUP BY, never re-parsed downstream. Row count == staging (tested).
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

SELECT
    vote_detail_id,
    meeting_id,
    meeting_type,
    vote_date,
    EXTRACT(YEAR FROM vote_date)                        AS vote_year,
    vote_number,
    agenda_description,
    -- one key per (meeting, item): the members' rows share it
    TO_HEX(MD5(CONCAT(IFNULL(meeting_id, ''), '|', IFNULL(CAST(vote_number AS STRING), ''), '|', IFNULL(agenda_description, '')))) AS item_key,
    council_member,
    vote,
    decision,
    vote = 'In Opposition'                              AS is_opposition,
    vote = 'Declared Conflict'                          AS is_conflict,
    REGEXP_CONTAINS(IFNULL(agenda_description, ''), r'(?i)\brezoning\b') AS is_rezoning,
    _synced_at
FROM {{ ref('stg_ca_vancouver_council_votes') }}
