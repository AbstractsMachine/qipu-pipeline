-- =============================================================================
-- Mart: where a US town's money comes from — town × fiscal year × document ×
-- shared revenue category × the state's own line, counted lines only.
--
-- Same perimeter as the spending mart for each state (see
-- int_us_lf_revenue_lines): MA general fund, IA / FL / CA all own funds.
-- Borrowing and transfers between funds are left out (counts_in_total).
-- =============================================================================

SELECT
    state,
    government_key,
    fiscal_year,
    document,
    fund_scope,
    category_code,
    category_label_en,
    category_label_fr,
    category_sort,
    COALESCE(source_label, '')                      AS subcategory,
    SUM(amount_usd)                                 AS amount_usd
FROM {{ ref('core_us_lf_revenue') }}
WHERE counts_in_total
  AND category_code IS NOT NULL
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
