-- =============================================================================
-- Core: bikeway segments, one row per published segment, with the engine's
-- four classes. `bike_class`: 4 separated (Protected Bike Lanes), 2 painted
-- lane (Painted Lanes), 3 shared (Shared Lanes, and Local Street bikeways —
-- a traffic-calmed street, not a lane). `year_built` = the City's own
-- year_of_construction ("the year the segment became an active bikeway").
-- Temporarily removed segments are kept and flagged.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core', 'citymap']) }}

SELECT
    bikeway_id, route_name, street_name, bikeway_type, status,
    CASE bikeway_type
        WHEN 'Protected Bike Lanes' THEN 4
        WHEN 'Painted Lanes'        THEN 2
        WHEN 'Shared Lanes'         THEN 3
        WHEN 'Local Street'         THEN 3
    END                                      AS bike_class,
    year_of_construction                     AS year_built,
    COALESCE(status, '') = 'Active'          AS is_active,
    geog,
    ST_LENGTH(geog)                          AS length_m,
    _synced_at
FROM {{ ref('stg_ca_vancouver_bikeways') }}
WHERE geog IS NOT NULL
