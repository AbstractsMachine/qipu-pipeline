-- =============================================================================
-- Mart: the lines behind each chart of the budget and debt pages — revenue by
-- source, expense by function, expense by object, reserves by group, the
-- balance sheet, and the property-tax share by class — one row per line ×
-- fiscal year, with its share of the printed section total.
--
-- Totals and the printed summary rows travel as their own rows (is_total /
-- is_summary) so the page never re-adds what the City already added.
-- comparable_from: the first fiscal year whose table uses the same set of
-- lines as the latest year (revenue was reclassified from the 2017 print on);
-- a series chart starts there, a single year can be read anywhere.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH l AS (
    SELECT *
    FROM {{ ref('core_ca_vancouver_finance_lines') }}
    WHERE table_name IN ('operations', 'expenses_by_object', 'capital_additions', 'reserves', 'financial_position', 'debt')
       OR (table_name = 'taxation' AND section_key = 'propertytaxrevenuebypropertyclass')
),

totals AS (
    SELECT table_name, section_key, fiscal_year, MAX(value_as_printed) AS section_total
    FROM l
    WHERE line_key = 'total'
    GROUP BY 1, 2, 3
),

sets AS (
    SELECT table_name, section_key, fiscal_year,
           STRING_AGG(line_key, ',' ORDER BY line_key) AS line_set
    FROM l
    WHERE NOT is_total
    GROUP BY 1, 2, 3
),

latest_set AS (
    SELECT table_name, section_key, line_set
    FROM sets
    QUALIFY ROW_NUMBER() OVER (PARTITION BY table_name, section_key ORDER BY fiscal_year DESC) = 1
),

comparable AS (
    -- walk back from the latest year while the line set holds
    SELECT s.table_name, s.section_key, MIN(s.fiscal_year) AS comparable_from
    FROM sets s
    JOIN latest_set ls USING (table_name, section_key)
    WHERE s.line_set = ls.line_set
      AND NOT EXISTS (
          SELECT 1 FROM sets s2
          WHERE s2.table_name = s.table_name AND s2.section_key IS NOT DISTINCT FROM s.section_key
            AND s2.fiscal_year > s.fiscal_year AND s2.line_set != ls.line_set)
    GROUP BY 1, 2
)

SELECT
    l.table_name,
    l.section_key,
    l.section,
    l.line_key,
    l.label,
    l.line_order,
    l.is_total,
    l.line_key IN ('annualsurplus', 'netfinancialassets', 'accumulatedsurplus', 'grandtotal') AS is_summary,
    l.fiscal_year,
    l.unit,
    l.amount_cad,
    l.value_as_printed,
    IF(NOT l.is_total AND l.unit = 'cad_thousands', SAFE_DIVIDE(l.value_as_printed, t.section_total), NULL) AS share_of_section,
    c.comparable_from,
    l.report_year,
    l.page,
    l.source_url,
    l.source_original_url
FROM l
LEFT JOIN totals t
  ON t.table_name = l.table_name AND t.section_key IS NOT DISTINCT FROM l.section_key AND t.fiscal_year = l.fiscal_year
LEFT JOIN comparable c
  ON c.table_name = l.table_name AND c.section_key IS NOT DISTINCT FROM l.section_key
