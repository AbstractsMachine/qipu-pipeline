-- =============================================================================
-- Core: the 2023–2026 Capital Plan, one row per program (revised at the 2026
-- budget). Row grain as published, unnamed rows included (11 rows carry
-- $32,968,778 of revised plan with no program name); marts roll up by category.
-- service_category_1: the plan file cuts long names at 36 characters; they are
-- written out from the budget files (core_ca_vancouver_capital_budget_lines
-- keeps one spelling per category).
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

WITH names AS (
    SELECT DISTINCT service_category_1 AS name FROM {{ ref('core_ca_vancouver_capital_budget_lines') }} WHERE service_category_1 IS NOT NULL
),

full_name AS (
    SELECT p.service_category_1 AS short,
           COALESCE(ARRAY_AGG(n.name IGNORE NULLS ORDER BY LENGTH(n.name) DESC LIMIT 1)[SAFE_OFFSET(0)], p.service_category_1) AS name
    FROM (SELECT DISTINCT service_category_1 FROM {{ ref('stg_ca_vancouver_capital_plan') }}) p
    LEFT JOIN names n
      ON LOWER(n.name) = LOWER(p.service_category_1)
      OR (LENGTH(p.service_category_1) >= 20 AND STARTS_WITH(n.name, p.service_category_1))
    GROUP BY 1
)

SELECT
    s.* REPLACE (f.name AS service_category_1),
    COALESCE({{ ca_org_key('s.program_name') }}, '') AS program_key
FROM {{ ref('stg_ca_vancouver_capital_plan') }} s
LEFT JOIN full_name f ON f.short = s.service_category_1
