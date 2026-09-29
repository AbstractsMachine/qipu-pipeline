-- Revenues − expenses = the annual surplus the City printed, each year (±3
-- thousand dollars of $000s rounding).
WITH y AS (
    SELECT fiscal_year,
           MAX(IF(section_key = 'revenues' AND line_key = 'total', value_as_printed, NULL)) AS revenues,
           MAX(IF(section_key = 'expenses' AND line_key = 'total', value_as_printed, NULL)) AS expenses,
           MAX(IF(line_key = 'annualsurplus', value_as_printed, NULL))                      AS surplus
    FROM {{ ref('core_ca_vancouver_finance_lines') }}
    WHERE table_name = 'operations'
    GROUP BY 1
)
SELECT * FROM y
WHERE revenues IS NULL OR expenses IS NULL OR surplus IS NULL OR ABS(revenues - expenses - surplus) > 3
