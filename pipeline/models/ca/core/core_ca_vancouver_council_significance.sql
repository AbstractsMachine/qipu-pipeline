-- =============================================================================
-- Core: one significance row per council record, the latest scored.
--
-- A record with no row has not been scored; the map then orders it by its
-- importance score alone. The public ranking (core_ca_vancouver_council_year_ranks)
-- chooses its candidates by this score first (RANKING.md, ranking-3).
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

SELECT record_key, significance, significance_kind, significance_version, scored_by, scored_at
FROM {{ ref('stg_ca_vancouver_council_significance') }}
WHERE significance BETWEEN 0 AND 100
QUALIFY ROW_NUMBER() OVER (PARTITION BY record_key ORDER BY scored_at DESC) = 1
