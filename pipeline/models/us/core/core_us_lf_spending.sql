-- =============================================================================
-- Core: US local government spending by shared category
--
-- Grain: one row per line_id (see int_us_lf_spending_lines).
--
-- Each source category is mapped to one of 12 shared categories through
-- seed_us_lf_category_map: an exact key beats a prefix, a longer prefix beats
-- a shorter one. An unmapped line stays, with category_code NULL and
-- is_mapped = FALSE, so coverage can be measured instead of assumed.
--
-- counts_in_total = FALSE marks transfers between a government's own funds:
-- summing them would count the same dollar twice.
--
-- category_code keeps construction inside its function (the Florida and
-- Census convention). Where a state files capital projects apart (Iowa),
-- compare against IF(spending_kind = 'capital', 'capital_projects', category_code).
-- =============================================================================

WITH lines AS (
    SELECT * FROM {{ ref('int_us_lf_spending_lines') }}
),

mapped AS (
    SELECT
        l.*,
        m.category_code,
        m.counts_in_total,
        m.confidence
    FROM lines l
    LEFT JOIN {{ ref('seed_us_lf_category_map') }} m
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
    mapped.source_system,
    government_key,
    government_name,
    gov_type,
    fiscal_year,
    document,
    fund_scope,
    is_general_fund,
    source_key,
    source_label,
    spending_kind,
    category_code,
    c.label_en                                  AS category_label_en,
    c.label_fr                                  AS category_label_fr,
    COALESCE(counts_in_total, TRUE)             AS counts_in_total,
    confidence,
    category_code IS NOT NULL                   AS is_mapped,
    -- the type of spending where the state records it (Indiana only, so far)
    nm.nature_code,
    amount_usd
FROM mapped
LEFT JOIN {{ ref('seed_us_lf_categories') }} c USING (category_code)
LEFT JOIN {{ ref('seed_us_lf_nature_map') }} nm
    ON nm.source_system = IF(mapped.source_system LIKE 'in_%', 'in', mapped.source_system)
   AND nm.source_value = UPPER(TRIM(mapped.nature_source))
