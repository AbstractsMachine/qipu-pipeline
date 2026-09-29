-- =============================================================================
-- Core: US local government revenue by shared category
--
-- Grain: one row per line_id (see int_us_lf_revenue_lines).
--
-- Each source line is mapped to one of 7 shared revenue categories through
-- seed_us_lf_revenue_map, by the same rule as spending: an exact key beats a
-- prefix, a longer prefix beats a shorter one. An unmapped line stays, with
-- category_code NULL and is_mapped = FALSE, so coverage is measured.
--
-- counts_in_total = FALSE: borrowing (money the town will repay) and
-- transfers between its own funds (the same dollar twice).
-- =============================================================================

WITH mapped AS (
    SELECT
        l.*,
        m.category_code,
        m.counts_in_total,
        m.confidence
    FROM {{ ref('int_us_lf_revenue_lines') }} l
    LEFT JOIN {{ ref('seed_us_lf_revenue_map') }} m
        ON m.source_system = l.source_system
       AND (
            (m.key_type = 'exact'  AND m.source_key = l.map_key)
         OR (m.key_type = 'prefix' AND STARTS_WITH(l.map_key, m.source_key))
       )
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY l.line_id
        ORDER BY IF(m.key_type = 'exact', 0, 1), LENGTH(m.source_key) DESC
    ) = 1
)

SELECT
    line_id,
    state,
    source_system,
    government_key,
    government_name,
    fiscal_year,
    document,
    fund_scope,
    source_key,
    source_label,
    category_code,
    c.label_en                                  AS category_label_en,
    c.label_fr                                  AS category_label_fr,
    c.sort_order                                AS category_sort,
    COALESCE(counts_in_total, TRUE)             AS counts_in_total,
    confidence,
    category_code IS NOT NULL                   AS is_mapped,
    amount_usd
FROM mapped
LEFT JOIN {{ ref('seed_us_lf_revenue_categories') }} c USING (category_code)
