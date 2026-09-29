-- =============================================================================
-- Mart: the pay ladder — employees over $75,000 by $25,000 band, per year.
-- Bands [75k,100k) … [175k,200k), then "200k and over" as one band so the top
-- of the ladder never isolates a handful of named senior managers.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

SELECT
    fiscal_year,
    LEAST(CAST(FLOOR(remuneration_cad / 25000) * 25000 AS INT64), 200000) AS band_floor_cad,
    COUNT(*)                                                             AS n_people,
    -- a band of one person's total is that person's pay: withheld under 10
    IF(COUNT(*) >= 10, SUM(remuneration_cad), NULL)                      AS remuneration_total_cad
FROM {{ ref('core_ca_vancouver_remuneration') }}
WHERE remuneration_cad >= 75000
GROUP BY 1, 2
