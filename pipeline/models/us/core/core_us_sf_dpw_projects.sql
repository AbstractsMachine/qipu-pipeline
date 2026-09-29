-- =============================================================================
-- Core: SF DPW projects (geolocated chantiers) — row-level OBT
--
-- Source: stg_us_sf_dpw_projects (typed, point geometry parsed).
-- Grain:  project × mapped point. Carries no money of its own.
-- =============================================================================

SELECT *
FROM {{ ref('stg_us_sf_dpw_projects') }}
