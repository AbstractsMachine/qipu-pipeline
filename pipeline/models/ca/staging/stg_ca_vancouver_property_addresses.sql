-- =============================================================================
-- Staging: civic address points — typed, one row per address point.
--
-- Source: raw.ca_vancouver_property_addresses (ODS property-addresses).
-- civic_number is text in the register; `civic_int` is its whole-number reading
-- (NULL where the register carries none). geo_point_2d is {lon,lat}. pcoord
-- joins the parcel's tax_coord.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

SELECT
    NULLIF(TRIM(SAFE_CAST(civic_number AS STRING)), '')          AS civic_number,
    SAFE_CAST(TRIM(SAFE_CAST(civic_number AS STRING)) AS INT64)  AS civic_int,
    NULLIF(UPPER(TRIM(SAFE_CAST(std_street AS STRING))), '')     AS std_street,
    NULLIF(TRIM(SAFE_CAST(pcoord AS STRING)), '')                AS pcoord,
    NULLIF(TRIM(SAFE_CAST(site_id AS STRING)), '')               AS site_id,
    NULLIF(TRIM(SAFE_CAST(geo_local_area AS STRING)), '')        AS local_area,
    SAFE_CAST(JSON_VALUE(SAFE_CAST(geo_point_2d AS STRING), '$.lon') AS FLOAT64) AS lon,
    SAFE_CAST(JSON_VALUE(SAFE_CAST(geo_point_2d AS STRING), '$.lat') AS FLOAT64) AS lat,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_property_addresses') }}
