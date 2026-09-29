-- =============================================================================
-- Staging: City of Vancouver population — Statistics Canada 2021 Census.
--
-- Source: seed_ca_vancouver_population (seeds/countries/ca/), one row per
--         census year with its StatCan Census Profile URL. The seed is the
--         raw layer here — a hand-verified official figure with its citation,
--         same role as stg_us_sf_population's Census row.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

SELECT
    year        AS census_year,
    population,
    geography,
    dguid,
    source,
    source_url
FROM {{ ref('seed_ca_vancouver_population') }}
