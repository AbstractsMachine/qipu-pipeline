-- =============================================================================
-- Staging: issued building permits (2017→), one row per permit, typed.
--
-- Source: raw.ca_vancouver_issued_building_permits (ODS issued-building-permits).
-- A permit is a decision the City's staff make, not council: the map shows it
-- as its own source, never mixed into the council record. Applicant and
-- contractor fields are dropped here — the map does not name who applied.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    NULLIF(TRIM(permitnumber), '')                                   AS permit_number,
    SAFE_CAST(SUBSTR(SAFE_CAST(issuedate AS STRING), 1, 10) AS DATE) AS issue_date,
    SAFE_CAST(projectvalue AS FLOAT64)                               AS project_value_cad,
    NULLIF(TRIM(typeofwork), '')                                     AS type_of_work,
    NULLIF(TRIM(address), '')                                        AS address,
    NULLIF(TRIM(permitcategory), '')                                 AS permit_category,
    NULLIF(TRIM(geolocalarea), '')                                   AS local_area,
    SAFE.ST_GEOGFROMGEOJSON(JSON_QUERY(SAFE_CAST(geom AS STRING), '$.geometry'), make_valid => TRUE) AS geog,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_issued_building_permits') }}
