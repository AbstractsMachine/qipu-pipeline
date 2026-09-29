-- =============================================================================
-- Staging: the SOFI PDFs every parsed Vancouver finance figure comes from.
--
-- Source: seed_ca_vancouver_sofi_documents (written by fetch_sofi.py): one row
--         per document, with the City's original URL (vancouver.ca refuses
--         scripted requests) and the Internet Archive capture the bytes were
--         read from, plus their SHA-256. `part` = statement | supply-management
--         (2017 and 2018 published the supplier and grant schedules apart).
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

SELECT
    fiscal_year,
    part,
    original_url,
    wayback_url,
    PARSE_DATE('%Y%m%d', SUBSTR(wayback_timestamp, 1, 8)) AS captured_on,
    sha256
FROM {{ ref('seed_ca_vancouver_sofi_documents') }}
