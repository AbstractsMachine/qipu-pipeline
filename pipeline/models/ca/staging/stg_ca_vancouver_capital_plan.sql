-- =============================================================================
-- Staging: the 2023–2026 Capital Plan as revised at the 2026 Capital Budget,
-- one row per program. Source: raw.ca_vancouver_capital_plan_2023_2026.
-- original → approved changes → revised plan; revised = city-led +
-- developer-led in-kind; city-led allocated to the 2023–2026 budgets, and the
-- remainder not yet allocated. Dollars as published.
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

SELECT
    TRIM(service_category_1)                                                            AS service_category_1,
    TRIM(service_category_2)                                                            AS service_category_2,
    TRIM(service_category_3)                                                            AS service_category_3,
    TRIM(project_program_name)                                                          AS program_name,
    CAST(`2023_2026_original_capital_plan` AS NUMERIC)                                  AS original_plan_cad,
    CAST(changes_to_2023_2026_capital_plan_approved_to_date AS NUMERIC)                 AS changes_approved_cad,
    CAST(changes_to_2023_2026_capital_plan_from_2026_capital_budget AS NUMERIC)         AS changes_2026_budget_cad,
    CAST(`2023_2026_revised_capital_plan` AS NUMERIC)                                   AS revised_plan_cad,
    CAST(revised_2023_2026_capital_plan_funding_development_contributions_developer_led_in_kind AS NUMERIC) AS developer_in_kind_cad,
    CAST(revised_2023_2026_capital_plan_funding_city_led AS NUMERIC)                    AS city_led_cad,
    CAST(`2023_2026_capital_plan_city_led_allocations_2023_approved_budget` AS NUMERIC) AS allocated_2023_cad,
    CAST(`2023_2026_capital_plan_city_led_allocations_2024_approved_budget` AS NUMERIC) AS allocated_2024_cad,
    CAST(`2023_2026_capital_plan_city_led_allocations_2025_approved_budget` AS NUMERIC) AS allocated_2025_cad,
    CAST(`2023_2026_capital_plan_city_led_allocations_2026_budget` AS NUMERIC)          AS allocated_2026_cad,
    CAST(remainder_of_2023_2026_capital_plan AS NUMERIC)                                AS remainder_cad,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_capital_plan_2023_2026') }}
