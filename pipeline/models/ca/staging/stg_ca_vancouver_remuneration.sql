-- =============================================================================
-- Staging: SOFI remuneration schedule — typed, one row per person × year.
--
-- Source: raw.ca_vancouver_employee_remuneration
--         (ODS employee-remuneration-and-expenses-earning-over-75000).
-- Fields verified live 2026-09-07: year, name, department, title,
-- remuneration, expenses. `year` arrives as a bare year string from the
-- export endpoint ('2025'); the records API returns an ISO timestamp → both
-- shapes are accepted.
--
-- PRIVACY: `name` identifies a real person. It is kept in staging/core for
-- grain integrity ONLY; no mart or export carries it — aggregate by
-- department, title, year. Same doctrine as Recife's CPF rule.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

SELECT
    -- The export endpoint returns a bare '2025'; the records API had returned
    -- an ISO timestamp for the same field. Accept both (measured 2026-09-12:
    -- the first shape parsed to NULL and silently emptied core).
    COALESCE(
        SAFE_CAST(SAFE_CAST(year AS STRING) AS INT64),
        EXTRACT(YEAR FROM SAFE_CAST(SAFE_CAST(year AS STRING) AS TIMESTAMP))
    )                                                  AS fiscal_year,
    NULLIF(TRIM(SAFE_CAST(name AS STRING)), '')        AS person_name,
    NULLIF(TRIM(SAFE_CAST(department AS STRING)), '')  AS department,
    NULLIF(TRIM(SAFE_CAST(title AS STRING)), '')       AS title,
    SAFE_CAST(remuneration AS NUMERIC)                 AS remuneration_cad,
    SAFE_CAST(expenses AS NUMERIC)                     AS expenses_cad,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_employee_remuneration') }}
