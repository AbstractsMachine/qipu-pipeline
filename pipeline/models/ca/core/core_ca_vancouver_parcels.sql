-- =============================================================================
-- Core: PARCELS OBT — one row per PARCEL (tax_coord), geometry dissolved from
-- its polygons, joined to the 2025 assessment roll rolled up to the parcel.
-- This is the unit money attaches to and the-city's base layer.
--
-- Grain, measured 2026-09-12: 99,701 published polygons → distinct tax_coord
-- parcels (multi-part parcels are ST_UNION_AGG'd; the 492 polygons with no
-- tax_coord stay in core_ca_vancouver_parcel_polygons only).
--
-- Join: tax_coord = roll.land_coordinate (never null in the roll; 1:1 per
-- parcel, verified live 2026-09-07). A parcel carries MANY roll rows when it
-- is strata (one per unit): n_properties, MIN(year_built), Σ values, Σ levy.
--
-- SURVIVORSHIP, stated: year_built describes buildings STANDING in 2025.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

WITH polys AS (
    SELECT
        tax_coord,
        COUNT(*)                        AS n_polygons,
        ST_UNION_AGG(parcel_geog)       AS parcel_geog,
        SUM(area_m2)                    AS area_m2,
        ANY_VALUE(civic_number)         AS civic_number,
        ANY_VALUE(street_name)          AS street_name,
        MAX(_synced_at)                 AS _synced_at
    FROM {{ ref('core_ca_vancouver_parcel_polygons') }}
    WHERE tax_coord IS NOT NULL
    GROUP BY tax_coord
),

roll AS (
    SELECT
        land_coordinate,
        COUNT(*)                          AS n_properties,
        MIN(year_built)                   AS year_built,
        MAX(big_improvement_year)         AS big_improvement_year,
        SUM(land_value_cad)               AS land_value_cad,
        SUM(improvement_value_cad)        AS improvement_value_cad,
        SUM(tax_levy_cad)                 AS tax_levy_cad,
        ANY_VALUE(zoning_district)        AS zoning_district,
        ANY_VALUE(zoning_classification)  AS zoning_classification,
        ANY_VALUE(neighbourhood_code)     AS neighbourhood_code,
        ANY_VALUE(report_year)            AS report_year
    FROM {{ ref('stg_ca_vancouver_property_tax') }}
    GROUP BY land_coordinate
)

SELECT
    p.tax_coord,
    p.n_polygons,
    p.civic_number,
    p.street_name,
    p.parcel_geog,
    ST_X(ST_CENTROID(p.parcel_geog)) AS lon,
    ST_Y(ST_CENTROID(p.parcel_geog)) AS lat,
    p.area_m2,
    r.n_properties,
    r.year_built,
    r.big_improvement_year,
    r.land_value_cad,
    r.improvement_value_cad,
    r.tax_levy_cad,
    r.zoning_district,
    r.zoning_classification,
    r.neighbourhood_code,
    r.report_year,
    r.land_coordinate IS NOT NULL AS has_roll_row,
    p._synced_at
FROM polys p
LEFT JOIN roll r ON r.land_coordinate = p.tax_coord
