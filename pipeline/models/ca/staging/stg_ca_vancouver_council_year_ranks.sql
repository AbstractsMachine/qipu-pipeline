-- =============================================================================
-- Staging: the public ranking of each year's council decisions (derived source).
--
-- Source: raw.ca_vancouver_council_year_ranks, written by
-- pipeline/scripts/ca_vancouver_city/reading/ingest_year_ranks.py (RANKING.md).
-- One row per record the ranking names: its place in the year's top 25, and the
-- record that stands for its group when it is one step of a matter.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

SELECT
    id                                   AS record_key,
    SAFE_CAST(year AS INT64)             AS rank_year,
    SAFE_CAST(public_rank AS INT64)      AS public_rank,
    NULLIF(item_group, '')               AS item_group,
    rv                                   AS ranking_version,
    model                                AS ranked_by,
    SAFE_CAST(ranked_at AS TIMESTAMP)    AS ranked_at,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_council_year_ranks') }}
