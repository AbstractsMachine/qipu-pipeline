-- =============================================================================
-- Intermediate: US local spending lines, every source in one shape (unmapped)
--
-- Grain: one row per (source_system, government_key, fiscal_year, document,
--        source_key[, fund/detail]) — `line_id` is unique.
--
-- document     'voted_budget' (what the town plans) | 'actual' (what it spent)
-- fund_scope   what the SOURCE covers: 'general_fund' (MA Schedule A, IN AFR by
--              department) | 'all_funds' (IA, FL, Census, IN budgets) — never
--              summed or compared across scopes.
-- is_general_fund  per line, where the source says (IN fund 0101; MA always):
--              IN budget general-fund lines vs IN actuals is the fair comparison.
--              Indiana's "Disbursements by Fund and Department" holds ONE fund —
--              the General Fund — in all 546 units (measured 2026-09-22).
-- An actual that is not filed yet is ABSENT, not zero: Iowa sends 0 for
-- unfiled years and Massachusetts all-zero rows, both dropped here.
--
-- spending_kind  'operating' | 'capital' | 'debt' | 'other'. Census files
-- construction apart (F codes) while Florida counts it INSIDE each function
-- (a fire station is public safety). Census F rows therefore keep their
-- function (map_key = E + the same two digits) and spending_kind = 'capital':
-- Florida vs Census by function moves from 1.33 to 1.13 on public works and
-- from 1.40 to 1.14 on recreation once capital is counted (measured
-- 2026-09-22, 378 and 339 municipalities).
--
-- nature_source: the type of spending where the state records it (Indiana:
-- the budget's expenditure category, the actuals' disbursement class —
-- salaries, services, supplies, capital, debt); NULL elsewhere.
--
-- Florida: the town's OWN funds only — governmental, enterprise and component
-- units. Fiduciary funds (custodial, agency, pension, trust, private purpose)
-- hold money for others: Jacksonville's custodial funds alone put $3.7B under
-- "Financial and Administrative" in 2024. Internal service funds re-spend what
-- departments already paid them (fleet, insurance, IT): counted twice. Both
-- are left out, as the Census leaves them out; they were 21% of the 2024 total
-- (measured 2026-09-22). The fund columns sum to total_account to the dollar.
-- =============================================================================

WITH ma AS (
    SELECT dor_code, municipality, fiscal_year, fn, amount
    FROM {{ ref('stg_us_ma_general_fund_expenditures') }}
    UNPIVOT (amount FOR fn IN (
        general_government_usd      AS 'general_government',
        public_safety_usd           AS 'public_safety',
        education_usd               AS 'education',
        public_works_usd            AS 'public_works',
        human_services_usd          AS 'human_services',
        culture_and_recreation_usd  AS 'culture_and_recreation',
        fixed_costs_usd             AS 'fixed_costs',
        intergov_assessments_usd    AS 'intergov_assessments',
        other_expenditures_usd      AS 'other_expenditures',
        debt_service_usd            AS 'debt_service'
    ))
    WHERE total_expenditures_usd > 0          -- year filed
),

ia AS (
    SELECT
        *,
        SUM(COALESCE(actual_usd, 0)) OVER (PARTITION BY city_code, fiscal_year) AS city_year_actual
    FROM {{ ref('stg_us_ia_city_expenditures') }}
),

ia_complete_years AS (
    -- A 926 year counts only once the state has published its proprietary
    -- funds (water, sewer, electricity...): FY2027 arrived without them — $0
    -- for all ~800 cities that had $4.04B the year before (measured
    -- 2026-09-22) — and would have shown every Iowa town cutting its budget.
    SELECT fiscal_year
    FROM {{ ref('stg_us_ia_city_budget_line_items') }}
    GROUP BY 1
    HAVING SUM(IF(fund = 'Proprietary Fund', budget_usd, 0)) > 0
),

ia_lines AS (
    -- Voted years that 925 does not reach yet, from the line items of the
    -- same certified budget; before that, 925 alone — the two are never
    -- summed for one year.
    SELECT
        city_code,
        ANY_VALUE(city_name)                                                AS city_name,
        fiscal_year,
        function_name,
        line_item,
        fund,
        SUM(budget_usd)                                                     AS budget_usd
    FROM {{ ref('stg_us_ia_city_budget_line_items') }}
    WHERE budget_usd IS NOT NULL AND budget_usd != 0
      AND fiscal_year > (SELECT MAX(fiscal_year) FROM ia WHERE budget_usd > 0)
      AND fiscal_year IN (SELECT fiscal_year FROM ia_complete_years)
    GROUP BY 1, 3, 4, 5, 6
),

fl AS (
    SELECT *,
        IFNULL(general_usd, 0) + IFNULL(special_revenue_usd, 0) + IFNULL(debt_service_usd, 0)
          + IFNULL(capital_projects_usd, 0) + IFNULL(permanent_usd, 0) + IFNULL(enterprise_usd, 0)
          + IFNULL(component_units_usd, 0)                                 AS own_funds_usd
    FROM {{ ref('stg_us_fl_municipal_expenditures') }}
    WHERE level = 'account'                   -- group rows are subtotals of these
),

ca AS (
    -- California's own funds: the internal service fund re-spends what
    -- departments paid it, conduit financing is debt issued for others, and
    -- enterprise depreciation is an accounting charge, not money spent (all
    -- three are mapped to counts_in_total = false in the seed).
    -- The SCO files one row per form line; grouped here so the key is unique.
    SELECT
        city_name,
        fiscal_year,
        category,
        subcategory_1,
        form_table,
        IF(form_table = 'DEPR_AMORT_EXP', 'DEPRECIATION',
           CONCAT(category, '|', subcategory_1, '|', COALESCE(ANY_VALUE(subcategory_2), ''))) AS map_key,
        -- the SCO suffixes every line with its form and fund ("Pumping_Water
        -- Enterprise Fund"); under a category the fund name alone reads better
        IF(category LIKE '%Enterprise Fund',
           TRIM(REGEXP_REPLACE(category, r'\s+', ' ')),
           TRIM(REGEXP_REPLACE(REGEXP_REPLACE(COALESCE(ANY_VALUE(subcategory_2), subcategory_1), r'_.*$', ''), r' [12]$', ''))) AS label,
        SUM(amount_usd) AS amount_usd
    FROM {{ ref('stg_us_ca_city_expenditures') }}
    WHERE amount_usd IS NOT NULL AND amount_usd != 0
    GROUP BY 1, 2, 3, 4, 5
),

census AS (
    SELECT f.*, u.unit_name, u.gov_type
    FROM {{ ref('stg_us_census_iuf_finance') }} f
    LEFT JOIN {{ ref('stg_us_census_iuf_units') }} u
        USING (unit_id, file_year)
    WHERE u.gov_type != 'state'                         -- the file also holds the 50 states (Medicaid E74/E75 alone: $3T over 2017-2024)
      AND (REGEXP_CONTAINS(f.item_code, r'^[EFGILM]')     -- expenditure codes
       OR f.item_code = '39U')                         -- + principal repaid (debt service = principal + interest)
),

in_budget AS (
    -- Indiana budget lines have no natural key (item text repeats): summed to
    -- unit × year × fund × department × expenditure category. "PROPERTY TAX
    -- CAP" lines record revenue lost to the state tax caps, not spending.
    SELECT
        CONCAT(county_code, '-', unit_code)                                  AS government_key,
        ANY_VALUE(unit_name)                                                 AS government_name,
        budget_year                                                          AS fiscal_year,
        IF(UPPER(department_name) = 'NO DEPARTMENT', 'in_fund', 'in_department') AS source_system,
        UPPER(TRIM(IF(UPPER(department_name) = 'NO DEPARTMENT', fund_name, department_name))) AS map_key,
        ANY_VALUE(IF(UPPER(department_name) = 'NO DEPARTMENT', fund_name, department_name)) AS source_label,
        CONCAT(fund_code, '|', department_code, '|', expenditure_category_code) AS detail,
        ANY_VALUE(fund_code) = '0101'                                        AS is_general_fund,
        CASE ANY_VALUE(expenditure_category)
            WHEN 'CAPITAL OUTLAYS' THEN 'capital'
            WHEN 'DEBT SERVICE'    THEN 'debt'
            ELSE 'operating'
        END                                                                  AS spending_kind,
        SUM(approved_usd)                                                    AS amount_usd,
        ANY_VALUE(expenditure_category)                                      AS nature_source
    FROM {{ ref('stg_us_in_budget_line_items') }}
    WHERE expenditure_category != 'PROPERTY TAX CAP'
    GROUP BY 1, 3, 4, 5, 7
),

in_actual AS (
    SELECT
        CONCAT(county_code, '-', unit_code)                                  AS government_key,
        ANY_VALUE(unit_name)                                                 AS government_name,
        fiscal_year,
        IF(department_name IS NULL OR UPPER(department_name) = 'NO DEPARTMENT', 'in_fund', 'in_department') AS source_system,
        UPPER(TRIM(IF(department_name IS NULL OR UPPER(department_name) = 'NO DEPARTMENT', fund_name, department_name))) AS map_key,
        ANY_VALUE(IF(department_name IS NULL OR UPPER(department_name) = 'NO DEPARTMENT', fund_name, department_name)) AS source_label,
        CONCAT(fund_code, '|', COALESCE(department_code, ''), '|', disbursement_class_code) AS detail,
        TRUE                                                                 AS is_general_fund,
        CASE
            WHEN REGEXP_CONTAINS(UPPER(ANY_VALUE(disbursement_class)), r'CAPITAL') THEN 'capital'
            WHEN REGEXP_CONTAINS(UPPER(ANY_VALUE(disbursement_class)), r'DEBT') THEN 'debt'
            ELSE 'operating'
        END                                                                  AS spending_kind,
        SUM(amount_usd)                                                      AS amount_usd,
        ANY_VALUE(disbursement_class)                                        AS nature_source
    FROM {{ ref('stg_us_in_afr_disbursements') }}
    GROUP BY 1, 3, 4, 5, 7
),

lines AS (
    SELECT 'MA' AS state, 'ma_schedule_a' AS source_system, dor_code AS government_key,
           municipality AS government_name, 'municipality' AS gov_type, fiscal_year,
           'actual' AS document, 'general_fund' AS fund_scope,
           fn AS source_key, fn AS map_key,
           -- The Schedule A column, in the words of the form itself.
           CASE fn
               WHEN 'fixed_costs'          THEN 'Fixed costs (pensions, insurance)'
               WHEN 'intergov_assessments' THEN 'State and county assessments'
               WHEN 'other_expenditures'   THEN 'Other spending'
               ELSE INITCAP(REPLACE(fn, '_', ' '))
           END AS source_label,
           CAST(NULL AS STRING) AS detail,
           CAST(NULL AS STRING) AS spending_kind, TRUE AS is_general_fund, amount AS amount_usd,
           CAST(NULL AS STRING) AS nature_source
    FROM ma

    UNION ALL
    SELECT 'IA', 'ia_dom_function', city_code, city_name, 'municipality', fiscal_year,
           'voted_budget', 'all_funds', function_name, function_name, function_name, NULL, NULL, NULL, budget_usd,
           NULL
    FROM ia

    UNION ALL
    SELECT 'IA', 'ia_dom_function', city_code, city_name, 'municipality', fiscal_year,
           'actual', 'all_funds', function_name, function_name, function_name, NULL, NULL, NULL, actual_usd,
           NULL
    FROM ia
    WHERE city_year_actual > 0                -- filed

    UNION ALL
    SELECT 'IA', 'ia_dom_function', city_code, city_name, 'municipality', fiscal_year,
           'voted_budget', 'all_funds', CONCAT(function_name, '|', line_item), function_name, line_item, fund,
           NULL, NULL, budget_usd,
           NULL
    FROM ia_lines

    UNION ALL
    SELECT 'FL', 'fl_uas_expenditure', municipality_file, municipality, 'municipality', fiscal_year,
           'actual', 'all_funds', account_code, account_code, account_name, NULL, NULL, NULL, own_funds_usd,
           NULL
    FROM fl
    WHERE own_funds_usd != 0

    UNION ALL
    SELECT 'CA', 'ca_sco_expenditure', city_name, city_name, 'municipality', fiscal_year,
           'actual', 'all_funds', CONCAT(category, '|', subcategory_1, '|', form_table), map_key, label, NULL,
           CASE
               WHEN subcategory_1 = 'Capital Outlay' THEN 'capital'
               WHEN subcategory_1 = 'Debt Service' OR form_table = 'INT_EXP' THEN 'debt'
               ELSE 'operating'
           END, NULL, amount_usd,
           NULL
    FROM ca

    UNION ALL
    SELECT 'IN', source_system, government_key, government_name, 'municipality', fiscal_year,
           'voted_budget', 'all_funds', map_key, map_key, source_label, detail, spending_kind, is_general_fund, amount_usd,
           nature_source
    FROM in_budget

    UNION ALL
    SELECT 'IN', source_system, government_key, government_name, 'municipality', fiscal_year,
           'actual', 'general_fund', map_key, map_key, source_label, detail, spending_kind, is_general_fund, amount_usd,
           nature_source
    FROM in_actual

    UNION ALL
    SELECT {{ us_state_abbr('census.state_fips') }}, 'census_iuf', unit_id, unit_name, gov_type, file_year,
           'actual', 'all_funds', item_code,
           IF(STARTS_WITH(item_code, 'F'), CONCAT('E', SUBSTR(item_code, 2)), item_code),
           item_code, NULL,
           CASE
               WHEN STARTS_WITH(item_code, 'E') THEN 'operating'
               WHEN REGEXP_CONTAINS(item_code, r'^[FG]') THEN 'capital'
               WHEN item_code = '39U' OR STARTS_WITH(item_code, 'I') THEN 'debt'
               ELSE 'other'
           END,
           NULL,
           amount_usd,
           NULL
    FROM census
)

SELECT
    TO_HEX(MD5(CONCAT(source_system, '|', government_key, '|', CAST(fiscal_year AS STRING), '|',
                      document, '|', source_key, '|', COALESCE(detail, '')))) AS line_id,
    *
FROM lines
WHERE amount_usd IS NOT NULL
