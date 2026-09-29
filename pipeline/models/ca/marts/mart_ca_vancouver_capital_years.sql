-- =============================================================================
-- Mart: the capital budget by year, 2021→2026 — the year's capital
-- expenditure budget, new multi-year project budgets approved that year and
-- (2023→) how they are funded, with the plan each year belongs to.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH cat AS (
    SELECT source_id, dataset_title, dataset_page_url, license_title, rows_updated_at
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
    WHERE STARTS_WITH(source_id, 'capital_budget_')
)

SELECT
    l.budget_year,
    ANY_VALUE(l.capital_plan)            AS capital_plan,
    COUNT(*)                             AS n_lines,
    COUNT(DISTINCT l.program_key)        AS n_programs,
    SUM(l.expenditure_budget_cad)        AS expenditure_budget_cad,
    SUM(l.new_multi_year_cad)            AS new_multi_year_cad,
    SUM(l.new_pay_as_you_go_cad)         AS new_pay_as_you_go_cad,
    SUM(l.new_debt_cad)                  AS new_debt_cad,
    SUM(l.new_tax_fee_reserves_cad)      AS new_tax_fee_reserves_cad,
    SUM(l.new_development_reserves_cad)  AS new_development_reserves_cad,
    SUM(l.new_connections_cad)           AS new_connections_cad,
    SUM(l.new_partner_cad)               AS new_partner_cad,
    SUM(l.total_open_cad)                AS total_open_cad,
    ANY_VALUE(c.dataset_title)           AS source_name,
    ANY_VALUE(c.dataset_page_url)        AS source_url,
    ANY_VALUE(c.license_title)           AS source_license,
    ANY_VALUE(c.rows_updated_at)         AS source_rows_updated_at
FROM {{ ref('core_ca_vancouver_capital_budget_lines') }} l
LEFT JOIN cat c ON c.source_id = CONCAT('capital_budget_', CAST(l.budget_year AS STRING))
GROUP BY 1
