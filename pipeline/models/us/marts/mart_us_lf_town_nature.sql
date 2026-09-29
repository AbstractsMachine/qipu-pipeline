-- =============================================================================
-- Mart: a US town's spending by TYPE (salaries, services, supplies,
-- construction, debt) — town × fiscal year × document × type, the "by
-- nature" cut of the French commune page. Only where the state records the
-- type: Indiana (budget expenditure category, AFR disbursement class), on the
-- same general-fund lines as its category mart.
-- =============================================================================

SELECT
    s.state,
    s.government_key,
    s.fiscal_year,
    s.document,
    s.nature_code,
    n.label_en                                      AS nature_label_en,
    n.label_fr                                      AS nature_label_fr,
    n.sort_order                                    AS nature_sort,
    SUM(s.amount_usd)                               AS amount_usd
FROM {{ ref('core_us_lf_spending') }} s
JOIN {{ ref('seed_us_lf_natures') }} n USING (nature_code)
WHERE s.source_system != 'census_iuf'
  AND s.counts_in_total
  AND (s.state != 'IN' OR s.is_general_fund)
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
