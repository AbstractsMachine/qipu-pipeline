-- =============================================================================
-- Mart: one row per curated landmark (seed_ca_vancouver_landmarks) with the
-- City money tied to it (core_ca_vancouver_landmark_money) and how it is
-- counted — the places section's figure, Paris's rule transposed:
--
--   counted = grants paid to the operator
--           + the WORKS, counted once: the new capital budgets of the
--             programs naming the place, or the contracts awarded naming it,
--             whichever is larger. Both record the same kind of spending on
--             the building (a contract is paid out of a capital budget), and
--             the two registers cover different years (budgets 2021→,
--             contracts 2013→), so adding them would count one project twice;
--             Paris's "paid, otherwise the contract ceilings — never both".
--
-- works_kind says which one counts ('capital' | 'contracts' | NULL when
-- neither is above zero); the other stays listed on the fiche, marked as not
-- added. years: the counted money by year (grants by fiscal year, capital by
-- budget year, contracts by award year) — it sums to counted_cad.
-- local_area: the local area whose polygon holds the point, else the nearest
-- within 1 km (a bridge's point is over the water).
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH lm AS (
    SELECT * FROM {{ ref('seed_ca_vancouver_landmarks') }}
),

m AS (
    SELECT * FROM {{ ref('core_ca_vancouver_landmark_money') }}
),

tot AS (
    SELECT lm.slug,
           COALESCE(SUM(IF(m.kind = 'grant', m.amount_cad, 0)), 0)    AS grants_cad,
           COALESCE(SUM(IF(m.kind = 'capital', m.amount_cad, 0)), 0)  AS capital_cad,
           COALESCE(SUM(IF(m.kind = 'contract', m.amount_cad, 0)), 0) AS contracts_cad,
           COUNTIF(m.kind = 'grant')                                   AS n_grant_lines,
           COUNT(DISTINCT IF(m.kind = 'capital', m.record_key, NULL))  AS n_programs,
           COUNT(DISTINCT IF(m.kind = 'contract', m.record_key, NULL)) AS n_contracts
    FROM lm
    LEFT JOIN m USING (slug)
    GROUP BY 1
),

rule AS (
    SELECT slug, grants_cad, capital_cad, contracts_cad, n_grant_lines, n_programs, n_contracts,
           CASE WHEN capital_cad > 0 AND capital_cad >= contracts_cad THEN 'capital'
                WHEN contracts_cad > 0 THEN 'contracts'
           END AS works_kind
    FROM tot
),

counted AS (
    -- the rows that make the figure: every grant line, and the works kind that counts
    SELECT m.*
    FROM m
    JOIN rule r USING (slug)
    WHERE m.kind = 'grant'
       OR (m.kind = 'capital' AND r.works_kind = 'capital')
       OR (m.kind = 'contract' AND r.works_kind = 'contracts')
),

yr AS (
    SELECT slug,
           ARRAY_AGG(STRUCT(year, grants_cad, works_cad, grants_cad + works_cad AS counted_cad) ORDER BY year) AS years,
           MIN(IF(grants_cad + works_cad != 0, year, NULL)) AS first_year,
           MAX(IF(grants_cad + works_cad != 0, year, NULL)) AS last_year
    FROM (
        SELECT slug, year,
               SUM(IF(kind = 'grant', amount_cad, 0))  AS grants_cad,
               SUM(IF(kind != 'grant', amount_cad, 0)) AS works_cad
        FROM counted
        GROUP BY 1, 2
    )
    GROUP BY 1
),

gr AS (
    -- the operator's grants, one row per payee and fiscal year, with the Statement's pages
    SELECT slug,
           ARRAY_AGG(STRUCT(record_key AS payee_key, payee_name, year, amount_cad, n_lines, source_url, pages)
                     ORDER BY year DESC, record_key) AS grants
    FROM (
        SELECT slug, record_key, year,
               ARRAY_AGG(record_label ORDER BY amount_cad DESC, record_id LIMIT 1)[OFFSET(0)] AS payee_name,
               SUM(amount_cad) AS amount_cad,
               COUNT(*) AS n_lines,
               ANY_VALUE(source_url) AS source_url,
               ARRAY_AGG(DISTINCT source_page IGNORE NULLS ORDER BY source_page) AS pages
        FROM m
        WHERE kind = 'grant'
        GROUP BY 1, 2, 3
    )
    GROUP BY 1
),

cap AS (
    SELECT slug,
           ARRAY_AGG(STRUCT(program_key, program_name, first_year, last_year, new_multi_year_cad, years)
                     ORDER BY last_year DESC, new_multi_year_cad DESC, program_key) AS capital
    FROM (
        SELECT slug, record_key AS program_key,
               ARRAY_AGG(record_label ORDER BY year DESC LIMIT 1)[OFFSET(0)] AS program_name,
               MIN(year) AS first_year, MAX(year) AS last_year,
               SUM(amount_cad) AS new_multi_year_cad,
               ARRAY_AGG(STRUCT(year, amount_cad, source_url) ORDER BY year) AS years
        FROM m
        WHERE kind = 'capital'
        GROUP BY 1, 2
    )
    GROUP BY 1
),

con AS (
    SELECT slug,
           ARRAY_AGG(STRUCT(record_key AS bid_number, record_label AS description, record_detail AS bid_type_group,
                            year AS award_year, amount_cad AS awarded_cad, source_url)
                     ORDER BY year DESC, amount_cad DESC, record_key) AS contracts
    FROM m
    WHERE kind = 'contract'
    GROUP BY 1
),

area AS (
    SELECT lm.slug, la.local_area
    FROM lm
    CROSS JOIN {{ ref('core_ca_vancouver_local_areas') }} la
    WHERE ST_DWITHIN(la.geog, ST_GEOGPOINT(lm.lon, lm.lat), 1000)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY lm.slug
                               ORDER BY ST_DISTANCE(la.geog, ST_GEOGPOINT(lm.lon, lm.lat)), la.local_area) = 1
)

SELECT
    lm.slug,
    lm.name,
    lm.kind,
    lm.family,
    lm.lat,
    lm.lon,
    lm.coord_source,
    a.local_area,
    ARRAY(SELECT TRIM(x) FROM UNNEST(SPLIT(COALESCE(lm.register_ids, ''), ';')) AS x WITH OFFSET o WHERE TRIM(x) != '' ORDER BY o) AS register_ids,
    lm.operator,
    ARRAY(SELECT TRIM(x) FROM UNNEST(SPLIT(COALESCE(lm.operator_payee_keys, ''), ';')) AS x WITH OFFSET o WHERE TRIM(x) != '' ORDER BY o) AS operator_payee_keys,
    lm.wikidata,
    lm.commons_file,
    lm.evidence,
    r.grants_cad,
    r.capital_cad,
    r.contracts_cad,
    r.works_kind,
    CASE r.works_kind WHEN 'capital' THEN r.capital_cad WHEN 'contracts' THEN r.contracts_cad ELSE 0 END AS works_cad,
    r.grants_cad + CASE r.works_kind WHEN 'capital' THEN r.capital_cad WHEN 'contracts' THEN r.contracts_cad ELSE 0 END AS counted_cad,
    r.n_grant_lines,
    r.n_programs,
    r.n_contracts,
    y.first_year,
    y.last_year,
    COALESCE(y.years, [])     AS years,
    COALESCE(g.grants, [])    AS grants,
    COALESCE(c.capital, [])   AS capital,
    COALESCE(k.contracts, []) AS contracts
FROM lm
JOIN rule r USING (slug)
LEFT JOIN area a USING (slug)
LEFT JOIN yr y USING (slug)
LEFT JOIN gr g USING (slug)
LEFT JOIN cap c USING (slug)
LEFT JOIN con k USING (slug)
