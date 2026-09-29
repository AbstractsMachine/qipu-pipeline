-- =============================================================================
-- Mart: capital expenditure budget and new multi-year budgets by service
-- category, per budget year. The category is the 2023–2026 plan's word
-- (seed_ca_vancouver_capital_category_crosswalk: "One Water" 2021–2022 →
-- "Water, sewers & drainage"), so one service is one series 2021→2026;
-- printed_categories keeps the name(s) that year's file used, and
-- capital_plan travels with every row.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

SELECT
    budget_year,
    capital_plan,
    service_category_1,
    ARRAY_AGG(DISTINCT service_category_1_printed IGNORE NULLS ORDER BY service_category_1_printed) AS printed_categories,
    COUNT(*)                        AS n_lines,
    SUM(expenditure_budget_cad)     AS expenditure_budget_cad,
    SUM(new_multi_year_cad)         AS new_multi_year_cad,
    SAFE_DIVIDE(SUM(expenditure_budget_cad), SUM(SUM(expenditure_budget_cad)) OVER (PARTITION BY budget_year)) AS share_of_year
FROM {{ ref('core_ca_vancouver_capital_budget_lines') }}
GROUP BY 1, 2, 3
