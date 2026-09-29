-- =============================================================================
-- Mart: Vancouver's finances, one row per fiscal year 2015→ — the headline
-- series the budget and debt pages chart. Every figure is a line of the SOFI
-- five-year review (core_ca_vancouver_finance_lines), in dollars.
--
-- population: the figure the City prints on its own debt table (source: BC
--             Stats, as the table says). expenses_per_resident_cad divides by
--             it — the City's own denominator, same year.
-- Columns are NULL where the review does not print the line for that year
-- (expenses by object and capital additions start with the 2022 report → 2018).
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH l AS (
    SELECT * FROM {{ ref('core_ca_vancouver_finance_lines') }}
),

y AS (
    SELECT
        fiscal_year,
        MAX(IF(table_name = 'operations' AND section_key = 'revenues' AND line_key = 'total', amount_cad, NULL))     AS revenues_cad,
        MAX(IF(table_name = 'operations' AND section_key = 'expenses' AND line_key = 'total', amount_cad, NULL))     AS expenses_cad,
        MAX(IF(table_name = 'operations' AND line_key = 'annualsurplus', amount_cad, NULL))                         AS surplus_cad,
        MAX(IF(table_name = 'operations' AND line_key = 'propertytaxespenaltiesandinterest', amount_cad, NULL))     AS property_tax_cad,
        MAX(IF(table_name = 'operations' AND line_key = 'developercontributions', amount_cad, NULL))                AS developer_contributions_cad,
        MAX(IF(table_name = 'capital_additions', amount_cad, NULL))                                                 AS capital_additions_cad,
        MAX(IF(table_name = 'expenses_by_object' AND line_key = 'wagessalariesandbenefits', amount_cad, NULL))      AS wages_cad,
        MAX(IF(table_name = 'debt' AND line_key = 'population', value_as_printed, NULL))                            AS population,
        MAX(IF(table_name = 'debt' AND line_key = 'debenturedebtoutstanding', amount_cad, NULL))                    AS debenture_debt_cad,
        MAX(IF(table_name = 'debt' AND line_key = 'externallyhelddebt', amount_cad, NULL))                          AS external_debt_cad,
        -- printed as "Less: Internally held debt (120,486)": the sign is the table's
        -MAX(IF(table_name = 'debt' AND line_key = 'lessinternallyhelddebt', amount_cad, NULL))                     AS internal_debt_cad,
        MAX(IF(table_name = 'debt' AND line_key = 'lesssinkingfundreserves', amount_cad, NULL))                     AS sinking_fund_cad,
        MAX(IF(table_name = 'debt' AND line_key = 'netexternallyhelddebt', amount_cad, NULL))                       AS net_external_debt_cad,
        MAX(IF(table_name = 'debt' AND line_key = 'grossdebtpercapitaexternallyheld', value_as_printed, NULL))      AS gross_debt_per_capita_cad,
        MAX(IF(table_name = 'debt' AND line_key = 'netdebtpercapitaexternallyheld', value_as_printed, NULL))        AS net_debt_per_capita_cad,
        MAX(IF(table_name = 'reserves' AND line_key = 'grandtotal', amount_cad, NULL))                              AS reserves_cad,
        MAX(IF(table_name = 'financial_position' AND line_key = 'accumulatedsurplus', amount_cad, NULL))            AS accumulated_surplus_cad,
        MAX(IF(table_name = 'financial_position' AND line_key = 'tangiblecapitalassets', amount_cad, NULL))         AS tangible_capital_assets_cad,
        MAX(IF(table_name = 'financial_position' AND line_key = 'netfinancialassets', amount_cad, NULL))            AS net_financial_assets_cad,
        MAX(IF(table_name = 'operations', report_year, NULL))                                                       AS operations_report_year,
        MAX(IF(table_name = 'operations', source_url, NULL))                                                        AS operations_source_url,
        MAX(IF(table_name = 'operations', page, NULL))                                                              AS operations_page,
        MAX(IF(table_name = 'debt', report_year, NULL))                                                             AS debt_report_year,
        MAX(IF(table_name = 'debt', source_url, NULL))                                                              AS debt_source_url,
        MAX(IF(table_name = 'debt', page, NULL))                                                                    AS debt_page
    FROM l
    GROUP BY 1
)

SELECT
    *,
    SAFE_DIVIDE(expenses_cad, population) AS expenses_per_resident_cad,
    SAFE_DIVIDE(revenues_cad, population) AS revenues_per_resident_cad
FROM y
