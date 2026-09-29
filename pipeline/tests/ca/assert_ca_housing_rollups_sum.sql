-- The housing page's cuts add up to its figure: the local areas and the
-- operators (completed buildings) each sum to the homes of the completed
-- buildings, the stages to every building's homes; an operator appears once
-- (one spelling per organisation), and an area's residents are never zero.
WITH b AS (SELECT * FROM {{ ref('mart_ca_vancouver_housing_buildings') }}),
r AS (SELECT * FROM {{ ref('mart_ca_vancouver_housing_rollups') }}),
want AS (
    SELECT SUM(IF(project_status = 'Completed', units, 0)) AS completed, SUM(units) AS all_stages FROM b
)
SELECT dimension, 'cut does not add up' AS problem
FROM r CROSS JOIN want
WHERE dimension IN ('local_area', 'operator', 'status')
GROUP BY dimension, want.completed, want.all_stages
HAVING SUM(r.units) != IF(dimension = 'status', want.all_stages, want.completed)
UNION ALL
SELECT LOWER(key), 'operator listed twice' FROM r WHERE dimension = 'operator' GROUP BY LOWER(key) HAVING COUNT(*) > 1
UNION ALL
SELECT key, 'area with zero residents' FROM r WHERE dimension = 'local_area' AND residents = 0
