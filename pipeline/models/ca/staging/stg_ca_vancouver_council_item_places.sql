-- =============================================================================
-- Staging: council item → parcel placements (derived source).
--
-- Source: raw.ca_vancouver_council_item_places, written by
-- pipeline/scripts/ca_vancouver_city/place_council_items.py: the address an
-- agenda item cites, matched in the City's property-addresses register.
-- `rule` says how: exact | range | hundred_block (same street, same hundred).
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    item_key,
    SAFE_CAST(civic_from AS INT64)    AS civic_from,
    SAFE_CAST(civic_to AS INT64)      AS civic_to,
    std_street,
    SAFE_CAST(civic_number AS INT64)  AS civic_number,
    NULLIF(TRIM(tax_coord), '')       AS tax_coord,
    rule,
    agenda_description_repaired,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_council_item_places') }}
