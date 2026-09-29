-- =============================================================================
-- Intermediate: SF operating budget vs actuals by department — FY2019+
--
-- Sources: core_us_sf_budget, core_us_sf_actuals, int_us_sf_departments
--          (display names), stg_us_sf_bva_outliers (editorial flag for the
--          departments whose residual is structural — seed, display only).
-- Grain:  fiscal_year × side × department_code (FULL OUTER join of the two
--         datasets, Operating funds, transfers and related-govt-units out).
-- Downstream: mart_us_sf_budget_vs_actual_dept adds provenance + execution
--             status. The perimeter logic used to live in that mart.
-- =============================================================================

WITH budget AS (
    SELECT
        fiscal_year,
        revenue_or_spending                              AS side,
        department_code,
        ANY_VALUE(department)                            AS department,
        ANY_VALUE(organization_group_code)               AS organization_group_code,
        ANY_VALUE(organization_group)                    AS organization_group,
        SUM(budget_amt)                                  AS budget_operating_usd
    FROM {{ ref('core_us_sf_budget') }}
    WHERE fiscal_year >= 2019
      AND fund_category = 'Operating'
      AND NOT is_transfer_character
    GROUP BY 1, 2, 3
    HAVING ABS(SUM(budget_amt)) > 0.005
),

actuals AS (
    SELECT
        fiscal_year,
        revenue_or_spending                              AS side,
        department_code,
        ANY_VALUE(department)                            AS department,
        ANY_VALUE(organization_group_code)               AS organization_group_code,
        ANY_VALUE(organization_group)                    AS organization_group,
        SUM(amount)                                      AS actual_operating_usd
    FROM {{ ref('core_us_sf_actuals') }}
    WHERE fiscal_year >= 2019
      AND fund_category = 'Operating'
      AND NOT is_related_govt_unit
      AND NOT is_transfer_character
    GROUP BY 1, 2, 3
    HAVING ABS(SUM(amount)) > 0.005
),

joined AS (
    SELECT
        COALESCE(b.fiscal_year, a.fiscal_year)             AS fiscal_year,
        COALESCE(b.side, a.side)                           AS side,
        COALESCE(b.department_code, a.department_code)     AS department_code,
        COALESCE(b.department, a.department)               AS department,
        COALESCE(b.organization_group_code, a.organization_group_code)
                                                           AS organization_group_code,
        COALESCE(b.organization_group, a.organization_group)
                                                           AS organization_group,
        b.budget_operating_usd,
        a.actual_operating_usd
    FROM budget b
    FULL OUTER JOIN actuals a
        USING (fiscal_year, side, department_code)
),

outliers AS (
    SELECT department_code, side, is_structural_outlier, outlier_note
    FROM {{ ref('stg_us_sf_bva_outliers') }}
)

SELECT
    j.*,
    n.display_name                                          AS department_display_name,
    COALESCE(o.is_structural_outlier, FALSE)                AS is_structural_outlier,
    o.outlier_note
FROM joined j
LEFT JOIN {{ ref('int_us_sf_departments') }} n
    ON n.department_code = j.department_code
LEFT JOIN outliers o
    ON o.department_code = j.department_code
   AND o.side = j.side
