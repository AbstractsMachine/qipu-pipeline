-- =============================================================================
-- Core: SOFI remuneration OBT — one row per person × fiscal year.
-- Carries person_name for grain integrity ONLY (privacy doctrine in the stg
-- header): marts aggregate to department / title / year and never emit it.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

SELECT
    fiscal_year,
    person_name,
    department,
    title,
    remuneration_cad,
    expenses_cad,
    _synced_at
FROM {{ ref('stg_ca_vancouver_remuneration') }}
WHERE fiscal_year IS NOT NULL
