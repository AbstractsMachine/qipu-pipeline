-- =============================================================================
-- Staging: the City's capital budgets 2021→2026, one typed shape.
--
-- Sources: raw.ca_vancouver_capital_budget_<year> — one portal dataset per
-- budget year, the year written INTO the column names
-- ("2026_new_multi_year_capital_project_budgets_requests_pay_as_you_go"), and
-- the columns changed with the 2023–2026 capital plan:
--   2021–2022 (2019–2022 plan): category / subcategory; new multi-year
--             budgets without a funding split.
--   2023–2026 (2023–2026 plan): service_category_1..3; new budgets split by
--             funding source; spending to date and budget available.
-- One row per program × budget year. Amounts are dollars as published (the
-- 2022 file carries cents). A tax/fee-reserve column arrives as STRING in 2026
-- (pandas inference): every amount is cast through STRING → NUMERIC.
-- Categories are the plan's own words and are NOT joined across the two plans
-- ("One Water" 2021 vs "Water, sewers & drainage" 2023): marts keep capital_plan.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

    SELECT
        2021 AS budget_year, '2019-2022' AS capital_plan,
        TRIM(service_category_1) AS service_category_1, TRIM(category) AS service_category_2, TRIM(subcategory) AS service_category_3,
        TRIM(project_program_name) AS program_name,
        SAFE_CAST(SAFE_CAST(multi_year_capital_budgets_previously_approved AS STRING) AS NUMERIC) AS previously_approved_cad,
        SAFE_CAST(SAFE_CAST(multi_year_capital_budgets_2021 AS STRING) AS NUMERIC) AS new_multi_year_cad,
        CAST(NULL AS NUMERIC) AS new_pay_as_you_go_cad,
        CAST(NULL AS NUMERIC) AS new_debt_cad,
        CAST(NULL AS NUMERIC) AS new_tax_fee_reserves_cad,
        CAST(NULL AS NUMERIC) AS new_development_reserves_cad,
        CAST(NULL AS NUMERIC) AS new_connections_cad,
        CAST(NULL AS NUMERIC) AS new_partner_cad,
        SAFE_CAST(SAFE_CAST(multi_year_capital_budgets_total_open_project_budget AS STRING) AS NUMERIC) AS total_open_cad,
        CAST(NULL AS NUMERIC) AS spent_to_prior_year_end_cad,
        CAST(NULL AS NUMERIC) AS available_cad,
        SAFE_CAST(SAFE_CAST(annual_capital_expenditure_budgets_2021 AS STRING) AS NUMERIC) AS expenditure_budget_cad,
        _synced_at
    FROM {{ source('ca_vancouver_raw', 'ca_vancouver_capital_budget_2021') }}
UNION ALL
    SELECT
        2022 AS budget_year, '2019-2022' AS capital_plan,
        TRIM(service_category_1) AS service_category_1, TRIM(category) AS service_category_2, TRIM(subcategory) AS service_category_3,
        TRIM(project_program_name) AS program_name,
        SAFE_CAST(SAFE_CAST(multi_year_capital_budgets_previously_approved AS STRING) AS NUMERIC) AS previously_approved_cad,
        SAFE_CAST(SAFE_CAST(multi_year_capital_budgets_2022 AS STRING) AS NUMERIC) AS new_multi_year_cad,
        CAST(NULL AS NUMERIC) AS new_pay_as_you_go_cad,
        CAST(NULL AS NUMERIC) AS new_debt_cad,
        CAST(NULL AS NUMERIC) AS new_tax_fee_reserves_cad,
        CAST(NULL AS NUMERIC) AS new_development_reserves_cad,
        CAST(NULL AS NUMERIC) AS new_connections_cad,
        CAST(NULL AS NUMERIC) AS new_partner_cad,
        SAFE_CAST(SAFE_CAST(multi_year_capital_budgets_total_open_project_budget AS STRING) AS NUMERIC) AS total_open_cad,
        CAST(NULL AS NUMERIC) AS spent_to_prior_year_end_cad,
        CAST(NULL AS NUMERIC) AS available_cad,
        SAFE_CAST(SAFE_CAST(annual_capital_expenditure_budgets_2022 AS STRING) AS NUMERIC) AS expenditure_budget_cad,
        _synced_at
    FROM {{ source('ca_vancouver_raw', 'ca_vancouver_capital_budget_2022') }}
UNION ALL
    SELECT
        2023 AS budget_year, '2023-2026' AS capital_plan,
        TRIM(service_category_1), TRIM(service_category_2), TRIM(service_category_3),
        TRIM(project_program_name),
        SAFE_CAST(SAFE_CAST(multi_year_capital_project_budgets_previously_approved_from_prior_capital_plans AS STRING) AS NUMERIC) AS previously_approved_cad,
        SAFE_CAST(SAFE_CAST(`2023_new_multi_year_capital_project_budgets_requests` AS STRING) AS NUMERIC) AS new_multi_year_cad,
        SAFE_CAST(SAFE_CAST(`2023_new_multi_year_capital_project_budgets_requests_pay_as_you_go` AS STRING) AS NUMERIC) AS new_pay_as_you_go_cad,
        SAFE_CAST(SAFE_CAST(`2023_new_multi_year_capital_project_budgets_requests_borrowing_authority_debt` AS STRING) AS NUMERIC) AS new_debt_cad,
        SAFE_CAST(SAFE_CAST(`2023_new_multi_year_capital_project_budgets_requests_tax_fee_funded_reserves` AS STRING) AS NUMERIC) AS new_tax_fee_reserves_cad,
        SAFE_CAST(SAFE_CAST(`2023_new_multi_year_capital_project_budgets_requests_reserves_cac_dcl_dbz_etc` AS STRING) AS NUMERIC) AS new_development_reserves_cad,
        SAFE_CAST(SAFE_CAST(`2023_new_multi_year_capital_project_budgets_requests_connections_servicing_conditions` AS STRING) AS NUMERIC) AS new_connections_cad,
        SAFE_CAST(SAFE_CAST(`2023_new_multi_year_capital_project_budgets_requests_partner_contributions` AS STRING) AS NUMERIC) AS new_partner_cad,
        SAFE_CAST(SAFE_CAST(multi_year_capital_project_budgets_total_open_project_budget_in_2023 AS STRING) AS NUMERIC) AS total_open_cad,
        SAFE_CAST(SAFE_CAST(spending_forecast_of_total_open_project_budgets_till_year_end_2022 AS STRING) AS NUMERIC) AS spent_to_prior_year_end_cad,
        SAFE_CAST(SAFE_CAST(available_project_budget_in_2023 AS STRING) AS NUMERIC) AS available_cad,
        SAFE_CAST(SAFE_CAST(annual_capital_expenditure_2023_capital_expenditure_budget AS STRING) AS NUMERIC) AS expenditure_budget_cad,
        _synced_at
    FROM {{ source('ca_vancouver_raw', 'ca_vancouver_capital_budget_2023') }}
UNION ALL
    SELECT
        2024 AS budget_year, '2023-2026' AS capital_plan,
        TRIM(service_category_1), TRIM(service_category_2), TRIM(service_category_3),
        TRIM(project_program_name),
        SAFE_CAST(SAFE_CAST(multi_year_capital_project_budgets_previously_approved_from_prior_capital_plans AS STRING) AS NUMERIC) AS previously_approved_cad,
        SAFE_CAST(SAFE_CAST(`2024_new_multi_year_capital_project_budgets_requests` AS STRING) AS NUMERIC) AS new_multi_year_cad,
        SAFE_CAST(SAFE_CAST(`2024_new_multi_year_capital_project_budgets_requests_pay_as_you_go` AS STRING) AS NUMERIC) AS new_pay_as_you_go_cad,
        SAFE_CAST(SAFE_CAST(`2024_new_multi_year_capital_project_budgets_requests_borrowing_authority_debt` AS STRING) AS NUMERIC) AS new_debt_cad,
        SAFE_CAST(SAFE_CAST(`2024_new_multi_year_capital_project_budgets_requests_tax_fee_funded_reserves` AS STRING) AS NUMERIC) AS new_tax_fee_reserves_cad,
        SAFE_CAST(SAFE_CAST(`2024_new_multi_year_capital_project_budgets_requests_reserves_cac_dcl_dbz_etc` AS STRING) AS NUMERIC) AS new_development_reserves_cad,
        SAFE_CAST(SAFE_CAST(`2024_new_multi_year_capital_project_budgets_requests_connections_servicing_conditions` AS STRING) AS NUMERIC) AS new_connections_cad,
        SAFE_CAST(SAFE_CAST(`2024_new_multi_year_capital_project_budgets_requests_partner_contributions` AS STRING) AS NUMERIC) AS new_partner_cad,
        SAFE_CAST(SAFE_CAST(multi_year_capital_project_budgets_total_open_project_budget_in_2024 AS STRING) AS NUMERIC) AS total_open_cad,
        SAFE_CAST(SAFE_CAST(spending_forecast_of_total_open_project_budgets_till_year_end_2023 AS STRING) AS NUMERIC) AS spent_to_prior_year_end_cad,
        SAFE_CAST(SAFE_CAST(available_project_budget_in_2024 AS STRING) AS NUMERIC) AS available_cad,
        SAFE_CAST(SAFE_CAST(annual_capital_expenditure_2024_capital_expenditure_budget AS STRING) AS NUMERIC) AS expenditure_budget_cad,
        _synced_at
    FROM {{ source('ca_vancouver_raw', 'ca_vancouver_capital_budget_2024') }}
UNION ALL
    SELECT
        2025 AS budget_year, '2023-2026' AS capital_plan,
        TRIM(service_category_1), TRIM(service_category_2), TRIM(service_category_3),
        TRIM(project_program_name),
        SAFE_CAST(SAFE_CAST(multi_year_capital_project_budgets_previously_approved_from_prior_capital_plans AS STRING) AS NUMERIC) AS previously_approved_cad,
        SAFE_CAST(SAFE_CAST(`2025_new_multi_year_capital_project_budgets_requests` AS STRING) AS NUMERIC) AS new_multi_year_cad,
        SAFE_CAST(SAFE_CAST(`2025_new_multi_year_capital_project_budgets_requests_pay_as_you_go` AS STRING) AS NUMERIC) AS new_pay_as_you_go_cad,
        SAFE_CAST(SAFE_CAST(`2025_new_multi_year_capital_project_budgets_requests_borrowing_authority_debt` AS STRING) AS NUMERIC) AS new_debt_cad,
        SAFE_CAST(SAFE_CAST(`2025_new_multi_year_capital_project_budgets_requests_tax_fee_funded_reserves` AS STRING) AS NUMERIC) AS new_tax_fee_reserves_cad,
        SAFE_CAST(SAFE_CAST(`2025_new_multi_year_capital_project_budgets_requests_reserves_cac_dcl_dbz_etc` AS STRING) AS NUMERIC) AS new_development_reserves_cad,
        SAFE_CAST(SAFE_CAST(`2025_new_multi_year_capital_project_budgets_requests_connections_servicing_conditions` AS STRING) AS NUMERIC) AS new_connections_cad,
        SAFE_CAST(SAFE_CAST(`2025_new_multi_year_capital_project_budgets_requests_partner_contributions` AS STRING) AS NUMERIC) AS new_partner_cad,
        SAFE_CAST(SAFE_CAST(multi_year_capital_project_budgets_total_open_project_budget_in_2025 AS STRING) AS NUMERIC) AS total_open_cad,
        SAFE_CAST(SAFE_CAST(spending_forecast_of_total_open_project_budgets_till_year_end_2024 AS STRING) AS NUMERIC) AS spent_to_prior_year_end_cad,
        SAFE_CAST(SAFE_CAST(available_project_budget_in_2025 AS STRING) AS NUMERIC) AS available_cad,
        SAFE_CAST(SAFE_CAST(annual_capital_expenditure_2025_capital_expenditure_budget AS STRING) AS NUMERIC) AS expenditure_budget_cad,
        _synced_at
    FROM {{ source('ca_vancouver_raw', 'ca_vancouver_capital_budget_2025') }}
UNION ALL
    SELECT
        2026 AS budget_year, '2023-2026' AS capital_plan,
        TRIM(service_category_1), TRIM(service_category_2), TRIM(service_category_3),
        TRIM(project_program_name),
        SAFE_CAST(SAFE_CAST(multi_year_capital_project_budgets_previously_approved_from_prior_capital_plans AS STRING) AS NUMERIC) AS previously_approved_cad,
        SAFE_CAST(SAFE_CAST(`2026_new_multi_year_capital_project_budgets_requests` AS STRING) AS NUMERIC) AS new_multi_year_cad,
        SAFE_CAST(SAFE_CAST(`2026_new_multi_year_capital_project_budgets_requests_pay_as_you_go` AS STRING) AS NUMERIC) AS new_pay_as_you_go_cad,
        SAFE_CAST(SAFE_CAST(`2026_new_multi_year_capital_project_budgets_requests_borrowing_authority_debt` AS STRING) AS NUMERIC) AS new_debt_cad,
        SAFE_CAST(SAFE_CAST(`2026_new_multi_year_capital_project_budgets_requests_tax_fee_funded_reserves` AS STRING) AS NUMERIC) AS new_tax_fee_reserves_cad,
        SAFE_CAST(SAFE_CAST(`2026_new_multi_year_capital_project_budgets_requests_reserves_cac_dcl_dbz_etc` AS STRING) AS NUMERIC) AS new_development_reserves_cad,
        SAFE_CAST(SAFE_CAST(`2026_new_multi_year_capital_project_budgets_requests_connections_servicing_conditions` AS STRING) AS NUMERIC) AS new_connections_cad,
        SAFE_CAST(SAFE_CAST(`2026_new_multi_year_capital_project_budgets_requests_partner_contributions` AS STRING) AS NUMERIC) AS new_partner_cad,
        SAFE_CAST(SAFE_CAST(multi_year_capital_project_budgets_total_open_project_budget_in_2026 AS STRING) AS NUMERIC) AS total_open_cad,
        SAFE_CAST(SAFE_CAST(spending_forecast_of_total_open_project_budgets_till_year_end_2025 AS STRING) AS NUMERIC) AS spent_to_prior_year_end_cad,
        SAFE_CAST(SAFE_CAST(available_project_budget_in_2026 AS STRING) AS NUMERIC) AS available_cad,
        SAFE_CAST(SAFE_CAST(annual_capital_expenditure_2026_capital_expenditure_budget AS STRING) AS NUMERIC) AS expenditure_budget_cad,
        _synced_at
    FROM {{ source('ca_vancouver_raw', 'ca_vancouver_capital_budget_2026') }}
