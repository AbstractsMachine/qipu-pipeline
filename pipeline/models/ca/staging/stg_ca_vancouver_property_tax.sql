-- =============================================================================
-- Staging: assessment roll, report_year 2025 — typed, one row per PROPERTY.
--
-- Source: raw.ca_vancouver_property_tax_report_2025 (ODS property-tax-report,
--         pulled with where=report_year='2025').
-- Grain:  pid (parcel identifier) — a strata unit is its own row; the PARCEL
--         is land_coordinate, shared by every unit in a building.
-- year_built: STRING in source; '1800' is a null placeholder (33 rows in
-- 2025, DATA AUDIT in configs/cities/vancouver.yaml) → NULL. Range after
-- cleaning 1886→2022.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

SELECT
    NULLIF(TRIM(SAFE_CAST(pid AS STRING)), '')                    AS pid,
    NULLIF(TRIM(SAFE_CAST(land_coordinate AS STRING)), '')        AS land_coordinate,
    NULLIF(TRIM(SAFE_CAST(legal_type AS STRING)), '')             AS legal_type,
    NULLIF(TRIM(SAFE_CAST(zoning_district AS STRING)), '')        AS zoning_district,
    NULLIF(TRIM(SAFE_CAST(zoning_classification AS STRING)), '')  AS zoning_classification,
    NULLIF(TRIM(SAFE_CAST(from_civic_number AS STRING)), '')      AS from_civic_number,
    NULLIF(TRIM(SAFE_CAST(to_civic_number AS STRING)), '')        AS to_civic_number,
    NULLIF(TRIM(SAFE_CAST(street_name AS STRING)), '')            AS street_name,
    NULLIF(TRIM(SAFE_CAST(property_postal_code AS STRING)), '')   AS postal_code,
    NULLIF(TRIM(SAFE_CAST(neighbourhood_code AS STRING)), '')     AS neighbourhood_code,
    SAFE_CAST(current_land_value AS NUMERIC)                      AS land_value_cad,
    SAFE_CAST(current_improvement_value AS NUMERIC)               AS improvement_value_cad,
    SAFE_CAST(tax_levy AS NUMERIC)                                AS tax_levy_cad,
    CASE
        WHEN SAFE_CAST(year_built AS INT64) BETWEEN 1850 AND 2100
            THEN SAFE_CAST(year_built AS INT64)
        ELSE NULL
    END                                                           AS year_built,
    SAFE_CAST(big_improvement_year AS INT64)                      AS big_improvement_year,
    SAFE_CAST(SAFE_CAST(report_year AS STRING) AS INT64)          AS report_year,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_property_tax_report_2025') }}
