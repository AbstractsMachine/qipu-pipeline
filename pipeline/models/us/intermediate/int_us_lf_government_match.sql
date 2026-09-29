-- =============================================================================
-- Intermediate: state government keys ↔ Census Individual Unit File units
--
-- Grain: one row per (state, source_system_group, government_key).
--
-- The state files each use their own ids (MA DOR code, IA city code, IN
-- county-unit, FL workbook name); Census uses a 12-char unit id. They meet on a
-- normalised name inside the state and the municipality/township types, using
-- the 2022 file (a census year: every local government is in it).
-- match_status: 'unique' | 'ambiguous' (several Census units share the
-- normalised name — kept unmatched rather than guessed) | 'unmatched'.
-- Pass 1 matches the state's name as written; pass 2, for what is left, the
-- name with a trailing type word removed ("City of X", "X Village").
-- Indiana civil cities and towns are Census MUNICIPALITIES: its townships are
-- separate governments that often share the name (90 false ambiguities).
-- =============================================================================

WITH gov AS (
    SELECT DISTINCT
        state,
        CASE WHEN source_system LIKE 'in_%' THEN 'in' ELSE source_system END AS source_group,
        government_key,
        FIRST_VALUE(government_name) OVER (
            PARTITION BY state, government_key ORDER BY fiscal_year DESC
        ) AS government_name
    FROM {{ ref('int_us_lf_spending_lines') }}
    WHERE source_system != 'census_iuf'
),

gov_norm AS (
    SELECT *,
        {{ us_lf_name_key('government_name') }}                  AS name_key,
        {{ us_lf_name_key('government_name', strip_type=true) }} AS name_key_stripped
    FROM gov
),

census AS (
    SELECT
        {{ us_state_abbr('state_fips') }}           AS state,
        unit_id,
        unit_name,
        gov_type,
        population,
        fips_place,
        {{ us_lf_name_key('unit_name', strip_type=true) }} AS name_key
    FROM {{ ref('stg_us_census_iuf_units') }}
    WHERE file_year = 2022
      AND gov_type IN ('municipality', 'township')
),

census_scoped AS (
    SELECT * FROM census
),

pass1 AS (
    SELECT g.*, c.unit_id, c.unit_name, c.gov_type AS census_gov_type, c.population, c.fips_place
    FROM gov_norm g
    JOIN census_scoped c
      ON c.state = g.state AND c.name_key = g.name_key
     AND (g.state != 'IN' OR c.gov_type = 'municipality')
),

pass2 AS (
    SELECT g.*, c.unit_id, c.unit_name, c.gov_type AS census_gov_type, c.population, c.fips_place
    FROM gov_norm g
    JOIN census_scoped c
      ON c.state = g.state AND c.name_key = g.name_key_stripped
     AND (g.state != 'IN' OR c.gov_type = 'municipality')
    WHERE NOT EXISTS (
        SELECT 1 FROM pass1 p
        WHERE p.state = g.state AND p.source_group = g.source_group AND p.government_key = g.government_key)
),

candidates AS (
    SELECT g.state, g.source_group, g.government_key, g.government_name, g.name_key,
           m.unit_id, m.unit_name, m.census_gov_type, m.population, m.fips_place,
           COUNT(m.unit_id) OVER (PARTITION BY g.state, g.source_group, g.government_key) AS n_candidates
    FROM gov_norm g
    LEFT JOIN (SELECT * FROM pass1 UNION ALL SELECT * FROM pass2) m
      USING (state, source_group, government_key)
)

SELECT
    state,
    source_group,
    government_key,
    government_name,
    name_key,
    CASE
        WHEN n_candidates = 1 THEN 'unique'
        WHEN n_candidates > 1 THEN 'ambiguous'
        ELSE 'unmatched'
    END                                             AS match_status,
    IF(n_candidates = 1, unit_id, NULL)             AS census_unit_id,
    IF(n_candidates = 1, unit_name, NULL)           AS census_unit_name,
    IF(n_candidates = 1, census_gov_type, NULL)     AS census_gov_type,
    IF(n_candidates = 1, population, NULL)          AS census_population_2022_file,
    IF(n_candidates = 1, fips_place, NULL)          AS fips_place,
    n_candidates
FROM candidates
QUALIFY ROW_NUMBER() OVER (PARTITION BY state, source_group, government_key ORDER BY unit_id) = 1
