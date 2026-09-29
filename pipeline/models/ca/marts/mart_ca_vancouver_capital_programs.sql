-- =============================================================================
-- Mart: one row per capital program key — its categories and name as the
-- latest budget prints them, and every budget year it appears in (expenditure
-- budget, new multi-year budget, open project budget). The explorer's list.
-- merged_keys: the printed keys seed_ca_vancouver_capital_program_merges
-- folded into this program (their old URLs redirect here).
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH y AS (
    SELECT program_key, budget_year,
           SUM(expenditure_budget_cad) AS expenditure_budget_cad,
           SUM(new_multi_year_cad)     AS new_multi_year_cad,
           SUM(total_open_cad)         AS total_open_cad
    FROM {{ ref('core_ca_vancouver_capital_budget_lines') }}
    GROUP BY 1, 2
),

latest AS (
    SELECT program_key, program_name, service_category_1, service_category_2, service_category_3, capital_plan, budget_year
    FROM {{ ref('core_ca_vancouver_capital_budget_lines') }}
    QUALIFY ROW_NUMBER() OVER (PARTITION BY program_key ORDER BY budget_year DESC, expenditure_budget_cad DESC NULLS LAST, program_name, line_id) = 1
),

merged AS (
    SELECT program_key, ARRAY_AGG(DISTINCT program_key_printed ORDER BY program_key_printed) AS merged_keys
    FROM {{ ref('core_ca_vancouver_capital_budget_lines') }}
    WHERE program_key != '' AND program_key_printed != program_key
    GROUP BY 1
),

arr AS (
    SELECT program_key,
           ARRAY_AGG(STRUCT(budget_year, expenditure_budget_cad, new_multi_year_cad, total_open_cad) ORDER BY budget_year) AS years,
           SUM(expenditure_budget_cad) AS expenditure_budget_all_years_cad,
           SUM(new_multi_year_cad)     AS new_multi_year_all_years_cad,
           MIN(budget_year) AS first_year, MAX(budget_year) AS last_year
    FROM y
    GROUP BY 1
)

SELECT
    l.program_key,
    l.program_name,
    l.service_category_1, l.service_category_2, l.service_category_3,
    l.capital_plan    AS latest_capital_plan,
    a.first_year, a.last_year,
    a.expenditure_budget_all_years_cad,
    a.new_multi_year_all_years_cad,
    a.years,
    COALESCE(mg.merged_keys, []) AS merged_keys
FROM latest l
JOIN arr a USING (program_key)
LEFT JOIN merged mg USING (program_key)
WHERE l.program_key != ''
