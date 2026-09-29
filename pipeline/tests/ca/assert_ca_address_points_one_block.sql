-- An address point stands in at most one block: the core keeps the register's
-- grain. A point on the shared edge of two block outlines is inside both, and
-- a plain point-in-polygon join counts it twice (it did: 99,822 rows from
-- 99,744 points). Returns a row when the core and the staged points disagree.
WITH s AS (
    SELECT COUNT(*) AS n FROM {{ ref('stg_ca_vancouver_property_addresses') }}
    WHERE lon IS NOT NULL AND lat IS NOT NULL
),
c AS (
    SELECT COUNT(*) AS n FROM {{ ref('core_ca_vancouver_property_addresses') }}
)
SELECT s.n AS staged_points, c.n AS core_rows
FROM s CROSS JOIN c
WHERE s.n != c.n
