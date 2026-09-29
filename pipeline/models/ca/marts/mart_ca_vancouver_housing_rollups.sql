-- =============================================================================
-- Mart: non-market housing rollups for the housing page, one long table —
-- dimension ∈ status | decade | local_area | operator — with buildings and
-- units (clientele count) by families / seniors / other. decade, local_area
-- and operator cover COMPLETED buildings only (homes that exist); status
-- covers all four stages.
-- residents (local_area rows): the 2021 Census residents of the census blocks
-- carried onto the area's city blocks (core_ca_vancouver_census_blocks, largest
-- overlap) — the same sum the city map's local-area panel prints — so the page
-- can say homes per 1,000 residents. payee_key (operator rows): the operator's
-- SOFI payee, when the same organisation is on the schedules. census_year and
-- city_residents (every row): the census those residents come from and the
-- City's own count in it (core_ca_vancouver_population), for the city-wide
-- rate — the area sums leave out the few census blocks no city block holds.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH b AS (SELECT * FROM {{ ref('mart_ca_vancouver_housing_buildings') }}),

long AS (
    SELECT 'status' AS dimension, project_status AS key, * FROM b
    UNION ALL
    SELECT 'decade', CAST(DIV(occupancy_year, 10) * 10 AS STRING), * FROM b WHERE project_status = 'Completed' AND occupancy_year IS NOT NULL
    UNION ALL
    SELECT 'local_area', COALESCE(local_area, 'Not located'), * FROM b WHERE project_status = 'Completed'
    UNION ALL
    SELECT 'operator', COALESCE(operator, 'Not given'), * FROM b WHERE project_status = 'Completed'
),

res AS (
    SELECT bl.local_area, SUM(c.population) AS residents, ANY_VALUE(c.source_url) AS residents_source_url
    FROM {{ ref('core_ca_vancouver_census_blocks') }} c
    JOIN {{ ref('core_ca_vancouver_blocks') }} bl USING (block_idx)
    WHERE bl.local_area IS NOT NULL
    GROUP BY 1
),

pop AS (
    SELECT census_year, population AS city_residents
    FROM {{ ref('core_ca_vancouver_population') }}
    QUALIFY ROW_NUMBER() OVER (ORDER BY census_year DESC) = 1
),

agg AS (
    SELECT
        dimension,
        key,
        COUNT(*)            AS n_buildings,
        SUM(units)          AS units,
        SUM(units_families) AS units_families,
        SUM(units_seniors)  AS units_seniors,
        SUM(units_other)    AS units_other,
        COUNTIF(NOT splits_agree) AS n_splits_disagree,
        IF(dimension = 'operator', ANY_VALUE(operator_payee_key), NULL) AS payee_key
    FROM long
    GROUP BY 1, 2
)

SELECT agg.*, res.residents, res.residents_source_url, pop.census_year, pop.city_residents
FROM agg
LEFT JOIN res ON agg.dimension = 'local_area' AND res.local_area = agg.key
CROSS JOIN pop
