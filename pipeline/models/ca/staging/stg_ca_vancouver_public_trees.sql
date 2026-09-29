-- =============================================================================
-- Staging: public trees (boulevards and parks), one row per tree asset.
--
-- Source: raw.ca_vancouver_public_trees (ODS public-trees). date_planted is
-- published on 78,323 of 185,845 trees (1989→): a planted year is what the
-- map's canopy grows from; an undated tree is drawn as standing (it predates
-- the register) and is never given an invented year. height_m is the City's
-- height CLASS midpoint, not a survey.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging', 'citymap']) }}

SELECT
    SAFE_CAST(asset_id AS INT64)                         AS tree_id,
    NULLIF(TRIM(common_name), '')                        AS common_name,
    NULLIF(TRIM(genus_name), '')                         AS genus_name,
    NULLIF(TRIM(species_name), '')                       AS species_name,
    SAFE_CAST(height_m AS FLOAT64)                       AS height_class_m,
    SAFE_CAST(diameter_cm AS FLOAT64)                    AS diameter_cm,
    SAFE_CAST(SUBSTR(SAFE_CAST(date_planted AS STRING), 1, 10) AS DATE) AS date_planted,
    SAFE.ST_GEOGFROMGEOJSON(JSON_QUERY(SAFE_CAST(geom AS STRING), '$.geometry'), make_valid => TRUE) AS geog,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_public_trees') }}
