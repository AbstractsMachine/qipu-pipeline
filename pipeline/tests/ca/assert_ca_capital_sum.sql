-- Σ capital expenditure budget survives raw → stg → core → mart per budget
-- year (to the cent; the 2022 file carries cents).
WITH raw_y AS (
    SELECT 2021 AS y, SUM(annual_capital_expenditure_budgets_2021) AS s FROM {{ source('ca_vancouver_raw', 'ca_vancouver_capital_budget_2021') }}
    UNION ALL SELECT 2022, SUM(annual_capital_expenditure_budgets_2022) FROM {{ source('ca_vancouver_raw', 'ca_vancouver_capital_budget_2022') }}
    UNION ALL SELECT 2023, SUM(annual_capital_expenditure_2023_capital_expenditure_budget) FROM {{ source('ca_vancouver_raw', 'ca_vancouver_capital_budget_2023') }}
    UNION ALL SELECT 2024, SUM(annual_capital_expenditure_2024_capital_expenditure_budget) FROM {{ source('ca_vancouver_raw', 'ca_vancouver_capital_budget_2024') }}
    UNION ALL SELECT 2025, SUM(annual_capital_expenditure_2025_capital_expenditure_budget) FROM {{ source('ca_vancouver_raw', 'ca_vancouver_capital_budget_2025') }}
    UNION ALL SELECT 2026, SUM(annual_capital_expenditure_2026_capital_expenditure_budget) FROM {{ source('ca_vancouver_raw', 'ca_vancouver_capital_budget_2026') }}
)
SELECT r.y, r.s, m.expenditure_budget_cad
FROM raw_y r
LEFT JOIN {{ ref('mart_ca_vancouver_capital_years') }} m ON m.budget_year = r.y
WHERE m.expenditure_budget_cad IS NULL OR ABS(CAST(r.s AS NUMERIC) - m.expenditure_budget_cad) > 0.05
