-- =============================================================================
-- Staging: awarded contracts (tender side) — typed, one row per award.
--
-- Source: raw.ca_vancouver_awarded_contracts (ODS awarded-contracts).
-- Fields verified live 2026-09-07: bid_number, bid_type, bid_description,
-- award_date, vendor_name, bid_amount, awarded.
-- NOTE: this is what the City POSTED and AWARDED, not what it PAID. The
-- payment side (suppliers >$25k) exists only in the SOFI PDF (2011→).
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

SELECT
    NULLIF(TRIM(SAFE_CAST(bid_number AS STRING)), '')      AS bid_number,
    NULLIF(TRIM(SAFE_CAST(bid_type AS STRING)), '')        AS bid_type,
    NULLIF(TRIM(SAFE_CAST(bid_description AS STRING)), '') AS bid_description,
    SAFE_CAST(SAFE_CAST(award_date AS STRING) AS DATE)     AS award_date,
    NULLIF(TRIM(SAFE_CAST(vendor_name AS STRING)), '')     AS vendor_name,
    SAFE_CAST(bid_amount AS NUMERIC)                       AS bid_amount_cad,
    NULLIF(TRIM(SAFE_CAST(awarded AS STRING)), '')         AS awarded,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_awarded_contracts') }}
