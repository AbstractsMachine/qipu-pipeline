-- Every section of Vancouver's five-year review sums to the total printed
-- under it, year by year (core_ca_vancouver_finance_lines reads each
-- table-year whole from one document — this is what proves it).
-- Tolerance: the tables print $000s rounded, so a section of n lines can be
-- off by up to n thousand; 3 has held for every section measured.
-- Summary rows printed beside the lines (annual surplus, net financial assets,
-- accumulated surplus) are not lines of the section.
WITH s AS (
    SELECT table_name, section_key, fiscal_year,
           SUM(IF(is_total OR line_key IN ('annualsurplus', 'netfinancialassets', 'accumulatedsurplus'), 0, value_as_printed)) AS lines_sum,
           MAX(IF(line_key = 'total', value_as_printed, NULL)) AS printed_total
    FROM {{ ref('core_ca_vancouver_finance_lines') }}
    WHERE table_name IN ('operations', 'expenses_by_object', 'financial_position', 'reserves')
      AND section_key NOT IN ('futuredebtrepayment', 'all')
    GROUP BY 1, 2, 3
)
SELECT *
FROM s
WHERE printed_total IS NULL OR ABS(lines_sum - printed_total) > 3
