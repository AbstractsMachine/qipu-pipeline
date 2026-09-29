-- =============================================================================
-- Core: one public-ranking row per council record, the latest ranking.
--
-- A record with no row was not named by the ranking: the map orders it by its
-- importance score (core_ca_vancouver_council_readings.interest) below the
-- ranked ones. `item_group` is the record that stands for a matter's steps;
-- the map shows the matter once, as that record.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

SELECT record_key, rank_year, public_rank, item_group, ranking_version, ranked_by, ranked_at
FROM {{ ref('stg_ca_vancouver_council_year_ranks') }}
QUALIFY ROW_NUMBER() OVER (PARTITION BY record_key ORDER BY ranked_at DESC) = 1
