-- =============================================================================
-- Staging: Iowa city certified budgets, line item × program × fund, FY2009+
--
-- Source: raw.us_ia_city_budget_line_items (data.iowa.gov dataset 926)
-- Grain:  one row per unique_line_id = city × fiscal year × budget-form line
--         × fund. Voted budget only (no actuals).
--
-- Same certified budget as dataset 925, in more detail: summed by program,
-- FY2025 equals 925's budget column (every program within $0.03B, measured
-- 2026-09-22). 926 runs two years further (FY2026, FY2027). Its program
-- names are written differently ("Culture & Recreation", "Transfers") and are
-- set here to 925's, so one crosswalk serves both.
-- =============================================================================

SELECT
    {{ us_lf_string('unique_line_id') }}                AS unique_line_id,
    {{ us_lf_int('fiscal_year') }}                      AS fiscal_year,
    {{ us_lf_string('city_code') }}                     AS city_code,
    {{ us_lf_string('city_name') }}                     AS city_name,
    {{ us_lf_string('gnis_feature_id') }}               AS gnis_feature_id,
    {{ us_lf_string('expense_line_item') }}             AS line_item,
    {{ us_lf_string('expenditure_program') }}           AS program_name,
    CASE TRIM(expenditure_program)
        WHEN 'Business Type/Enterprise' THEN 'Business Type / Enterprise'
        WHEN 'Transfers'                THEN 'Transfers Out Total'
        ELSE REPLACE(TRIM(expenditure_program), ' & ', ' and ')
    END                                                 AS function_name,
    {{ us_lf_string('fund') }}                          AS fund,
    {{ us_lf_amount('value') }}                         AS budget_usd,
    _source                                             AS source,
    _source_url                                         AS source_url,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_ia_city_budget_line_items') }}
