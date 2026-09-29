-- =============================================================================
-- Core: Vancouver's consolidated finances 2015→, one row per table × section
-- × line × fiscal year. A table's year is read WHOLE from the latest SOFI that
-- prints it.
--
-- Why latest: every five-year review restates the four years before it (new
-- accounting standards — PS 3280 asset retirement in 2023, PS 3400 revenue in
-- 2025 — and reclassifications). The newest print of a year is the City's
-- current figure for it; `report_year` says which document that is.
-- Why whole tables: picking the newest print line by line mixed two
-- classifications in one year (2017–2020 revenues summed old "Cost recoveries,
-- grants and donations" AND new "Government transfers" — 16 lines against a
-- printed total of 12). One document per table-year keeps every year's lines
-- summing to its own printed total (assert_ca_finance_sections_sum).
-- Misprints: a later report can print a row wrong (2023–2025 shift capital
-- additions one column). seed_ca_vancouver_sofi_review_misprints lists each,
-- with the statement text that proves it; that table-year is read from the
-- previous report instead.
--
-- line_key: the letters-only label key, with the rename the City made joined
-- to one line so a series does not break at it:
--   communityandculturalservices → artscultureandcommunityservices (2022)
-- A classification CHANGE is not a rename and is not joined: "Cost recoveries,
-- grants and donations" + "Revenue sharing" (≤2016 prints) became
-- "Government transfers" + "Cost recoveries and donations" (2017→ prints).
--
-- units: amount_cad is DOLLARS — the tables print $000s, multiplied here;
-- population is persons; per-capita debt lines are dollars as printed; tax
-- rates are per $1,000 of assessment; class shares are percent.
-- label: as the latest report prints it (older prints are letter-spaced).
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

WITH r0 AS (
    -- Reserves print "Future Debt Repayment" and the grand total AFTER the last
    -- group's subtotal, so the parser files them under that group; they are
    -- their own group and the whole table's total.
    SELECT
        * REPLACE (
            CASE WHEN table_name = 'reserves' AND label_key = 'futuredebtrepayment' THEN 'futuredebtrepayment'
                 WHEN table_name = 'reserves' AND label_key = 'grandtotal'          THEN 'all'
                 ELSE section_key END AS section_key,
            CASE WHEN table_name = 'reserves' AND label_key = 'futuredebtrepayment' THEN label
                 WHEN table_name = 'reserves' AND label_key = 'grandtotal'          THEN 'All reserves'
                 ELSE section END AS section
        )
    FROM {{ ref('stg_ca_vancouver_sofi_review') }}
),

r AS (
    SELECT
        *,
        CASE label_key
            WHEN 'communityandculturalservices' THEN 'artscultureandcommunityservices'
            ELSE label_key
        END AS line_key
    FROM r0
),

misprints AS (
    SELECT report_year, table_name, fiscal_year_from, fiscal_year_to
    FROM {{ ref('seed_ca_vancouver_sofi_review_misprints') }}
),

newest AS (
    SELECT r.table_name, r.fiscal_year, MAX(r.report_year) AS report_year
    FROM r
    LEFT JOIN misprints m
      ON m.report_year = r.report_year AND m.table_name = r.table_name
     AND r.fiscal_year BETWEEN m.fiscal_year_from AND m.fiscal_year_to
    WHERE m.report_year IS NULL
    GROUP BY 1, 2
),

latest AS (
    SELECT r.*
    FROM r
    JOIN newest USING (table_name, fiscal_year, report_year)
),

labels AS (
    SELECT table_name, section_key, line_key,
           ARRAY_AGG(STRUCT(label, section, line_no) ORDER BY report_year DESC, line_no LIMIT 1)[OFFSET(0)] AS l
    FROM r
    GROUP BY 1, 2, 3
),

docs AS (
    SELECT fiscal_year AS report_year, original_url, wayback_url
    FROM {{ ref('stg_ca_vancouver_sofi_documents') }}
    WHERE part = 'statement'
)

SELECT
    x.table_name,
    x.section_key,
    COALESCE(lb.l.section, x.section)                  AS section,
    x.line_key,
    COALESCE(lb.l.label, x.label)                      AS label,
    lb.l.line_no                                       AS line_order,
    x.is_total,
    x.fiscal_year,
    CASE
        WHEN x.table_name = 'taxation'                                         THEN 'as_printed'
        WHEN x.line_key = 'population'                                         THEN 'persons'
        WHEN x.line_key LIKE '%percapita%'                                     THEN 'cad'
        ELSE 'cad_thousands'
    END                                                AS unit,
    IF(x.table_name != 'taxation' AND x.line_key != 'population' AND x.line_key NOT LIKE '%percapita%',
       x.value * 1000, NULL)                           AS amount_cad,
    x.value                                            AS value_as_printed,
    x.report_year,
    x.page,
    d.original_url                                     AS source_original_url,
    d.wayback_url                                      AS source_url
FROM latest x
LEFT JOIN labels lb
  ON lb.table_name = x.table_name AND lb.section_key IS NOT DISTINCT FROM x.section_key
 AND lb.line_key IS NOT DISTINCT FROM x.line_key
LEFT JOIN docs d ON d.report_year = x.report_year
