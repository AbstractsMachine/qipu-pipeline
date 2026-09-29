-- =============================================================================
-- Core: SF Budget OBT — row-level adopted AAO budget lines
--
-- Source: stg_us_sf_budget
-- Grain:  row-level (FY × side × org/dept/program × character/object/
--         sub_object × fund hierarchy) — rollups live in marts (ADR-0001).
--
-- Adds reconciliation-relevant flags (see mart_us_sf_budget_vs_actual):
--   - is_transfer_adjustment: the embedded NEGATIVE "Transfer Adjustment"
--     rows that net the budget total — kept, never dropped (naive
--     SUM(budget_amt) is net precisely because of them).
--   - is_transfer_character: any transfer character (in/out/adjustment) —
--     the transfer perimeter used when comparing against gross actuals.
--   - is_fiscal_year_complete: SF fiscal year N runs Jul 1 (N-1) → Jun 30 N;
--     FY2027 is present because SF budgets two years at a time.
-- =============================================================================

WITH budget AS (
    SELECT *
    FROM {{ ref('stg_us_sf_budget') }}
),

-- Editorial plain-English gloss per (side, character) — seed, display only.
character_glosses AS (
    SELECT side, character_code, gloss, display_category, provenance
    FROM {{ ref('stg_us_sf_character_glosses') }}
),

-- Editorial department display names — seed, display only.
dept_names AS (
    SELECT department_code, display_name, provenance
    FROM {{ ref('stg_us_sf_dept_names') }}
)

SELECT
    b.*,
    STARTS_WITH(UPPER(COALESCE(b.character, '')), 'TRANSFER ADJUSTMENT')
                                                       AS is_transfer_adjustment,
    UPPER(COALESCE(b.character, '')) LIKE '%TRANSFER%'   AS is_transfer_character,
    CURRENT_DATE('America/Los_Angeles') > DATE(b.fiscal_year, 6, 30)
                                                       AS is_fiscal_year_complete
    ,
    g.gloss                            AS character_gloss,
    g.display_category                 AS character_display_category,
    g.provenance                       AS character_gloss_provenance,
    n.display_name                     AS department_display_name,
    n.provenance                       AS department_display_name_provenance
FROM budget b
LEFT JOIN character_glosses g
    ON g.side = b.revenue_or_spending
   AND g.character_code = b.character_code
LEFT JOIN dept_names n
    ON n.department_code = b.department_code
