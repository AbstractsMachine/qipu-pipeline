-- Expenses by object and expenses by function are the same money cut two
-- ways: their totals agree each year (±3 thousand of $000s rounding). Read
-- from different tables, so this also catches a shifted or duplicated column
-- in either (the 2022 report's object table repeats 2019 in its 2020 column —
-- later reports supersede those years; this proves the years that survive).
WITH y AS (
    SELECT fiscal_year,
           MAX(IF(table_name = 'operations' AND section_key = 'expenses' AND line_key = 'total', value_as_printed, NULL)) AS by_function,
           MAX(IF(table_name = 'expenses_by_object' AND line_key = 'total', value_as_printed, NULL))                     AS by_object
    FROM {{ ref('core_ca_vancouver_finance_lines') }}
    GROUP BY 1
)
SELECT * FROM y
WHERE by_object IS NOT NULL AND ABS(by_function - by_object) > 3
