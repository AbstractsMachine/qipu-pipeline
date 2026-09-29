-- =============================================================================
-- Staging: council minutes motion → parcel placements (derived source).
--
-- Source: raw.ca_vancouver_minutes_places, written by
-- pipeline/scripts/ca_vancouver_city/place_minutes.py for both collections of
-- minutes (the 1970s scans and the 1995–2015 Wayback copies). `rule` says how:
-- legal | legal_lot_dl (a lot, block and district lot on today's assessment
-- roll) or exact | range | hundred_block (a civic address in today's register).
-- `cited` is the words in the minutes that placed it.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    motion_key,
    source,
    SAFE_CAST(meeting_date AS DATE)    AS meeting_date,
    NULLIF(TRIM(tax_coord), '')        AS tax_coord,
    rule,
    cited,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_minutes_places') }}
