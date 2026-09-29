-- =============================================================================
-- Staging: SOFI payment schedules — suppliers over $25,000 and grants — as
-- one typed stream, one row per printed line.
--
-- Sources: raw.ca_vancouver_sofi_suppliers, raw.ca_vancouver_sofi_grants
--          (parse_sofi.py, from the Internet Archive copies of the PDFs).
-- payee_key: macro ca_org_key — spelling variants of one organisation (legal
--            form, "Vanc."/"Prov." abbreviations) share a key; the payees mart
--            joins contract vendors on the same macro.
--
-- PRIVACY: `is_individual` flags lines whose payee is a person's name (the
-- parser's conservative rule). The name is kept here for grain integrity
-- ONLY; no mart or export carries it — those lines are counted and summed.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

WITH s AS (
    SELECT fiscal_year, 'suppliers' AS schedule, CAST(NULL AS STRING) AS category,
           name, amount_cad, is_individual, amendment AS is_amendment, page, _synced_at
    FROM {{ source('ca_vancouver_raw', 'ca_vancouver_sofi_suppliers') }}
    UNION ALL
    SELECT fiscal_year, 'grants', category,
           name, amount_cad, is_individual, FALSE, page, _synced_at
    FROM {{ source('ca_vancouver_raw', 'ca_vancouver_sofi_grants') }}
)

SELECT
    fiscal_year,
    schedule,
    NULLIF(TRIM(category), '')                                          AS category,
    REGEXP_REPLACE(TRIM(name), r'\s+', ' ')                             AS payee_name,
    {{ ca_org_key('name') }}                                            AS payee_key,
    CAST(amount_cad AS NUMERIC)                                         AS amount_cad,
    COALESCE(is_individual, FALSE)                                      AS is_individual,
    COALESCE(is_amendment, FALSE)                                       AS is_amendment,
    page,
    _synced_at
FROM s
WHERE name IS NOT NULL AND amount_cad IS NOT NULL
