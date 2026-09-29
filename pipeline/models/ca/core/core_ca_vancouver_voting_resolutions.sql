-- =============================================================================
-- Core: one minutes item per voting-record decision, where the match held.
--
-- The page it came from is the Wayback Machine's copy of the City's minutes
-- (`minutes_doc` is the cached file: <date>/<name>); the capture itself is listed
-- in seed_ca_vancouver_minutes_wayback. The City's website carries no open
-- licence: the text is read to state what was decided, and is not republished.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

SELECT item_key, meeting_date, minutes_doc, minutes_heading, resolution_text, match_cover, match_shared
FROM {{ ref('stg_ca_vancouver_voting_resolutions') }}
WHERE resolution_text IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY match_cover DESC, match_shared DESC) = 1
