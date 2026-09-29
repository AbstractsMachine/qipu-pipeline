-- The capital category crosswalk (seed_ca_vancouver_capital_category_crosswalk)
-- stays sound:
--   · every row carries a reason;
--   · a printed name is mapped once, and never onto a name the seed itself maps
--     (no chains);
--   · the printed name is still printed by some budget year (a stale row fails);
--   · the target is a category of the 2023–2026 Capital Plan, so every service
--     series ends on a name the current plan uses;
--   · after the crosswalk, no budget year still carries a category the seed maps.
WITH x AS (SELECT * FROM {{ ref('seed_ca_vancouver_capital_category_crosswalk') }}),
core AS (SELECT DISTINCT budget_year, service_category_1, service_category_1_printed FROM {{ ref('core_ca_vancouver_capital_budget_lines') }}),
plan AS (SELECT DISTINCT service_category_1 FROM {{ ref('mart_ca_vancouver_capital_plan') }})
SELECT printed_category, 'no reason' AS problem FROM x WHERE reason IS NULL OR TRIM(reason) = ''
UNION ALL
SELECT printed_category, 'mapped twice' FROM x GROUP BY printed_category HAVING COUNT(*) > 1
UNION ALL
SELECT x.printed_category, 'chain: target is also mapped' FROM x JOIN x t ON t.printed_category = x.category
UNION ALL
SELECT x.printed_category, 'printed name not in the budgets' FROM x
WHERE x.printed_category NOT IN (SELECT service_category_1_printed FROM core WHERE service_category_1_printed IS NOT NULL)
UNION ALL
SELECT x.printed_category, 'target not a 2023-2026 plan category' FROM x
WHERE x.category NOT IN (SELECT service_category_1 FROM plan WHERE service_category_1 IS NOT NULL)
UNION ALL
SELECT DISTINCT c.service_category_1, CONCAT('still printed after the crosswalk in ', CAST(c.budget_year AS STRING))
FROM core c JOIN x ON x.printed_category = c.service_category_1
