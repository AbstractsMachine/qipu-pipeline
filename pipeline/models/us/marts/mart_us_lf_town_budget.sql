-- =============================================================================
-- Mart: what a US town page shows — town × fiscal year × document × shared
-- category × the state's own sub-category, counted lines only.
--
-- Scope rule (never compare across fund scopes): a page pairs a voted budget
-- and actuals of the SAME scope. Indiana's actuals hold the general fund only,
-- so its page shows general-fund lines for both documents (fund 0101); the
-- all-funds voted total is carried apart in mart_us_lf_towns. Massachusetts
-- actuals are general fund, its voted budget a TOTAL (no category), also in
-- mart_us_lf_towns. Census lines are not a town page source.
--
-- Indiana's department names come from the state's form, written for every
-- unit at once: "Police Department (Town Marshall)", "Clerk-Treasurer
-- (City/Town Units Only)", some in capitals, some cut mid-parenthesis. The page
-- shows them without the form's parenthesis and in normal case; int_ keeps
-- them verbatim.
-- =============================================================================

WITH stripped AS (
    SELECT
        s.*,
        IF(s.state = 'IN', TRIM(REGEXP_REPLACE(s.source_label, r'\s*\([^)]*(\)|$)', '')), s.source_label) AS label_x
    FROM {{ ref('core_us_lf_spending') }} s
),

lines AS (
    SELECT
        *,
        IF(state = 'IN' AND label_x = UPPER(label_x),
           REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
               INITCAP(label_x), ' Of ', ' of '), ' And ', ' and '), ' The ', ' the '),
               ' For ', ' for '), ' In ', ' in '), ' To ', ' to '),
           label_x) AS display_label
    FROM stripped
)

SELECT
    s.state,
    s.government_key,
    s.fiscal_year,
    s.document,
    s.fund_scope,
    s.category_code,
    s.category_label_en,
    s.category_label_fr,
    c.sort_order                                    AS category_sort,
    s.display_label                                 AS subcategory,
    SUM(s.amount_usd)                               AS amount_usd
FROM lines s
LEFT JOIN {{ ref('seed_us_lf_categories') }} c USING (category_code)
WHERE s.source_system != 'census_iuf'
  AND s.counts_in_total
  AND (s.state != 'IN' OR s.is_general_fund)
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
