-- =============================================================================
-- Mart: what a US town builds — its capital spending, town × fiscal year ×
-- document × line, the "Ce qu'elle construit" block of the French commune
-- page. Each state records it its own way; `basis` says which, and the page
-- says it too:
--   capital_outlay       Indiana (the all-funds budget's "Capital Outlays",
--                        voted only) and California (governmental "Capital
--                        Outlay", by function)
--   capital_projects     Iowa: its "Capital Projects" function (budget and
--                        actuals; certified line items for the years ahead)
--   capital_projects_fund Florida: what its capital projects funds spent
-- Massachusetts reports its general fund only: no capital figure.
-- =============================================================================

WITH core AS (
    SELECT
        state, government_key, fiscal_year, document,
        CASE
            WHEN state IN ('IN', 'CA') AND spending_kind = 'capital' THEN 'capital_outlay'
            WHEN state = 'IA' AND category_code = 'capital_projects' THEN 'capital_projects'
        END                                             AS basis,
        -- Indiana's fund names come in capitals with the form's parenthesis:
        -- shown as the town budget mart shows them
        IF(state = 'IN',
           (SELECT IF(x = UPPER(x),
                      REPLACE(REPLACE(REPLACE(REPLACE(INITCAP(x), ' Of ', ' of '), ' And ', ' and '), ' The ', ' the '), ' For ', ' for '),
                      x)
            FROM UNNEST([TRIM(REGEXP_REPLACE(source_label, r'\s*\([^)]*(\)|$)', ''))]) AS x),
           COALESCE(NULLIF(source_label, ''), category_label_en)) AS label,
        amount_usd
    FROM {{ ref('core_us_lf_spending') }}
    WHERE source_system != 'census_iuf'
      AND counts_in_total
      -- Indiana builds through its capital funds (cumulative capital
      -- development, bond funds), not the general fund: its general-fund
      -- actuals show $0.11B of capital for every town together in 2025, its
      -- all-funds budget $0.73B in 2026. The all-funds VOTED budget is used,
      -- and no Indiana actual (the state publishes departmental actuals for
      -- the general fund only).
      AND NOT (state = 'IN' AND document = 'actual')
),

fl AS (
    SELECT
        'FL'                                            AS state,
        municipality_file                               AS government_key,
        fiscal_year,
        'actual'                                        AS document,
        'capital_projects_fund'                         AS basis,
        account_name                                    AS label,
        SUM(capital_projects_usd)                       AS amount_usd
    FROM {{ ref('stg_us_fl_municipal_expenditures') }}
    WHERE level = 'account' AND IFNULL(capital_projects_usd, 0) != 0
    GROUP BY 1, 2, 3, 4, 5, 6
)

SELECT state, government_key, fiscal_year, document, basis, label, SUM(amount_usd) AS amount_usd
FROM core
WHERE basis IS NOT NULL
GROUP BY 1, 2, 3, 4, 5, 6
UNION ALL
SELECT * FROM fl
