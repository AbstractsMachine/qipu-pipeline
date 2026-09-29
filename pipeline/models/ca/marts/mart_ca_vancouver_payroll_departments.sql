-- =============================================================================
-- Mart: employees over $75,000 by department × year, with the department's
-- titles. `department` is the City's label that year (renamed over time:
-- "Fire and Rescue Services" → "VFRS"); rows are as printed, not joined
-- across renames.
-- titles: every title held by at least 3 people in that department-year;
-- smaller titles are summed into one "fewer than 3" row so no title row is a
-- single person's pay.
-- median_cad: NULL for a group of fewer than 10 people — the median of a small
-- group is one member's pay (of 5, exactly the third).
-- A department-year of fewer than 3 people is not a row (2026-09-23): its
-- total would be one or two people's pay (Mayor & City Council listed a
-- single employee 2009–2014). Those people stay in the year's totals
-- (mart_ca_vancouver_payroll_years) and in share_of_year's denominator; the
-- floor is the one the title rows already use.
-- department_display: the label written out where the City abbreviates it
-- ("Dev Svcs, Bldg & Licensing" → "Development, Buildings & Licensing"), from
-- the reviewed seed_ca_vancouver_payroll_department_names; the City's own
-- label stays in `department`, and the slug is still built from it (URLs do
-- not move).
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH t AS (
    SELECT fiscal_year, department, title,
           COUNT(*) AS n, SUM(remuneration_cad) AS total_cad,
           IF(COUNT(*) >= 10, APPROX_QUANTILES(remuneration_cad, 2)[OFFSET(1)], NULL) AS median_cad
    FROM {{ ref('core_ca_vancouver_remuneration') }}
    GROUP BY 1, 2, 3
),

titles AS (
    SELECT fiscal_year, department,
           ARRAY_AGG(IF(n >= 3, STRUCT(title, n AS n_people, total_cad, median_cad), NULL) IGNORE NULLS ORDER BY n DESC, title) AS titles,
           SUM(IF(n < 3, n, 0))         AS n_people_small_titles,
           SUM(IF(n < 3, total_cad, 0)) AS total_small_titles_cad,
           COUNTIF(n < 3)               AS n_small_titles
    FROM t
    GROUP BY 1, 2
),

d AS (
    SELECT fiscal_year, department,
           COUNT(*) AS n_people, SUM(remuneration_cad) AS remuneration_total_cad,
           IF(COUNT(*) >= 10, APPROX_QUANTILES(remuneration_cad, 100)[OFFSET(50)], NULL) AS median_cad,
           SUM(expenses_cad) AS expenses_total_cad
    FROM {{ ref('core_ca_vancouver_remuneration') }}
    GROUP BY 1, 2
)

, joined AS (
    SELECT
        d.*,
        COALESCE(nm.display_name, d.department) AS department_display,
        REGEXP_REPLACE(REGEXP_REPLACE(LOWER(COALESCE(d.department, 'unassigned')), r'[^a-z0-9]+', '-'), r'^-|-$', '') AS department_slug,
        SAFE_DIVIDE(d.remuneration_total_cad, SUM(d.remuneration_total_cad) OVER (PARTITION BY d.fiscal_year)) AS share_of_year,
        COALESCE(tt.titles, [])        AS titles,
        tt.n_people_small_titles,
        tt.total_small_titles_cad,
        tt.n_small_titles
    FROM d
    LEFT JOIN titles tt
      ON tt.fiscal_year = d.fiscal_year AND tt.department IS NOT DISTINCT FROM d.department
    LEFT JOIN {{ ref('seed_ca_vancouver_payroll_department_names') }} nm
      ON nm.department = d.department
)

SELECT * FROM joined
WHERE n_people >= 3
