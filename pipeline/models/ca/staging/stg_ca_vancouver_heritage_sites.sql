-- =============================================================================
-- Staging: the Vancouver Heritage Register, one row per listed site.
--
-- Source: raw.ca_vancouver_heritage_sites (ODS). `evaluation_group` is the
-- register's own tier (A, B, C, or N/A); the designation columns are the
-- register's Yes/No flags, folded to BOOL ("Y" and "Yes" both occur). Names are
-- as printed, abbreviations included; "N/A" is the register publishing no name
-- and becomes NULL. `geog` is the register's point.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    SAFE_CAST(id AS INT64)                                          AS heritage_id,
    NULLIF(NULLIF(TRIM(buildingnamespecifics), ''), 'N/A')          AS site_name,
    NULLIF(TRIM(category), '')                                      AS category,
    NULLIF(NULLIF(TRIM(evaluationgroup), ''), 'N/A')                AS evaluation_group,
    UPPER(TRIM(municipaldesignationm)) IN ('Y', 'YES')              AS is_municipal_designation,
    UPPER(TRIM(provincialdesignationp)) IN ('Y', 'YES')             AS is_provincial_designation,
    UPPER(TRIM(federaldesignationf)) IN ('Y', 'YES')                AS is_federal_designation,
    NULLIF(TRIM(streetnumber), '')                                  AS street_number,
    NULLIF(TRIM(streetname), '')                                    AS street_name,
    NULLIF(TRIM(localarea), '')                                     AS local_area,
    NULLIF(TRIM(status), '')                                        AS status,
    SAFE_CAST(JSON_VALUE(geo_point_2d, '$.lon') AS FLOAT64)         AS lon,
    SAFE_CAST(JSON_VALUE(geo_point_2d, '$.lat') AS FLOAT64)         AS lat,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_heritage_sites') }}
