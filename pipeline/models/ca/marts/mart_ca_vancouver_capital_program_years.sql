-- =============================================================================
-- Mart: one row per capital program key × budget year — the program fiche:
-- categories as that year's file prints them, previously approved budget, the
-- new multi-year budget and (2023→) its funding split, total open budget,
-- spending to the prior year-end, budget available, and the year's
-- expenditure budget. Lines a file repeats for one program are summed.
-- program_name is the name that year's file printed (a merged program keeps
-- each year's own spelling); service_category_1 is the 2023–2026 plan's word
-- and service_category_1_printed the year's. When a file lists a program on
-- several lines, the labels are the largest line's (ANY_VALUE picked a
-- different sub-category from one build to the next).
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH l AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY program_key, budget_year
                              ORDER BY expenditure_budget_cad DESC NULLS LAST, new_multi_year_cad DESC NULLS LAST, line_id) AS rk
    FROM {{ ref('core_ca_vancouver_capital_budget_lines') }}
    WHERE program_key != ''
)

SELECT
    program_key,
    budget_year,
    MAX(IF(rk = 1, program_name, NULL))               AS program_name,
    MAX(IF(rk = 1, capital_plan, NULL))               AS capital_plan,
    MAX(IF(rk = 1, service_category_1, NULL))         AS service_category_1,
    MAX(IF(rk = 1, service_category_1_printed, NULL)) AS service_category_1_printed,
    MAX(IF(rk = 1, service_category_2, NULL))         AS service_category_2,
    MAX(IF(rk = 1, service_category_3, NULL))         AS service_category_3,
    COUNT(*)                           AS n_lines,
    SUM(previously_approved_cad)       AS previously_approved_cad,
    SUM(new_multi_year_cad)            AS new_multi_year_cad,
    SUM(new_pay_as_you_go_cad)         AS new_pay_as_you_go_cad,
    SUM(new_debt_cad)                  AS new_debt_cad,
    SUM(new_tax_fee_reserves_cad)      AS new_tax_fee_reserves_cad,
    SUM(new_development_reserves_cad)  AS new_development_reserves_cad,
    SUM(new_connections_cad)           AS new_connections_cad,
    SUM(new_partner_cad)               AS new_partner_cad,
    SUM(total_open_cad)                AS total_open_cad,
    SUM(spent_to_prior_year_end_cad)   AS spent_to_prior_year_end_cad,
    SUM(available_cad)                 AS available_cad,
    SUM(expenditure_budget_cad)        AS expenditure_budget_cad
FROM l
GROUP BY 1, 2
