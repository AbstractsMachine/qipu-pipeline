-- =============================================================================
-- Core: population by census year, with its StatCan citation.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

SELECT census_year, population, geography, dguid, source, source_url
FROM {{ ref('stg_ca_vancouver_population') }}
