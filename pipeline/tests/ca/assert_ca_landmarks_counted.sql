-- A landmark's figure is grants + the works counted ONCE (the larger of the
-- capital budgets and the contracts, never both), and its year series adds up
-- to it — the rail, the list and the fiche say one number.
WITH l AS (SELECT * FROM {{ ref('mart_ca_vancouver_landmarks') }}),
y AS (
    SELECT slug, SUM(yy.counted_cad) AS s, SUM(yy.grants_cad) AS g, SUM(yy.works_cad) AS w
    FROM l, UNNEST(l.years) AS yy
    GROUP BY 1
)
SELECT slug, 'counted is not grants + works' AS problem FROM l WHERE ABS(counted_cad - (grants_cad + works_cad)) > 0.5
UNION ALL
SELECT slug, 'works is not the larger of capital and contracts' FROM l WHERE ABS(works_cad - GREATEST(capital_cad, contracts_cad, 0)) > 0.5
UNION ALL
SELECT l.slug, 'years do not add up to the figure' FROM l LEFT JOIN y USING (slug) WHERE ABS(l.counted_cad - COALESCE(y.s, 0)) > 0.5
UNION ALL
SELECT l.slug, 'years mix up grants and works' FROM l JOIN y USING (slug) WHERE ABS(l.grants_cad - y.g) > 0.5 OR ABS(l.works_cad - y.w) > 0.5
