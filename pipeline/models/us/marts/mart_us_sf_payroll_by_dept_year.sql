-- =============================================================================
-- Mart: SF payroll by department × fiscal year — PUBLISHED rows only
--
-- Sources: core_us_sf_comp (year_type = 'Fiscal'), core_us_sf_source_catalog.
-- Grain:  department_code × fiscal year, 2013-2025 (~730 published rows).
--
-- KEYED ON department_code — the #1 payroll trap (block study §5, bug
-- reproduced live): department LABELS break at FY2017 ("POL Police" →
-- "Police"; 61 codes ↔ 125 label pairs). Codes are stable across all 13
-- years; every row carries the CANONICAL label = the label of the code's
-- most recent year. Grouping by label instead of code silently zeroes
-- every pre-2017 department series.
--
-- PRIVACY (dial B, approved): department-years with fewer than 5 distinct
-- employees are NOT published — in practice the Law Library (n=2-3 every
-- year), one Sheriff-oversight code (n=1, FY2022) and two FY2017 rows with
-- a NULL department code. Their dollars stay inside the citywide totals
-- (mart_us_sf_comp_by_year) but get no department row; the fold is
-- ≤ $560k/yr (≤0.01% of comp) and is asserted ≤ 4 employees/yr by
-- tests/us/assert_us_sf_payroll_dept_totals_match_by_year.sql. Org-group
-- totals must always be computed FROM these published rows (never
-- independently), so the fold cannot be recovered by subtraction.
--
-- median_total_comp_usd is the median of per-employee totals WITHIN the
-- department (an employee working in two departments counts in each, with
-- the comp earned there) — exact PERCENTILE_CONT, not a sketch.
-- =============================================================================

WITH fiscal AS (
    SELECT *
    FROM {{ ref('core_us_sf_comp') }}
    WHERE year_type = 'Fiscal'
      AND department_code IS NOT NULL
),

-- Canonical (latest-year) label per department code; deterministic
-- tie-break on the label itself if a code carries two labels in its
-- latest year.
canonical_dept AS (
    SELECT
        department_code,
        department,
        organization_group_code,
        organization_group
    FROM (
        SELECT
            department_code,
            department,
            organization_group_code,
            organization_group,
            ROW_NUMBER() OVER (
                PARTITION BY department_code
                ORDER BY year DESC, department ASC
            ) AS rn
        FROM fiscal
        GROUP BY department_code, department,
                 organization_group_code, organization_group, year
    )
    WHERE rn = 1
),

dept_year AS (
    SELECT
        year,
        department_code,
        COUNT(DISTINCT employee_identifier)  AS n_employees,
        SUM(salaries)                        AS salaries_usd,
        SUM(overtime)                        AS overtime_usd,
        SUM(other_salaries)                  AS other_salaries_usd,
        SUM(total_salary)                    AS total_salary_usd,
        SUM(retirement)                      AS retirement_usd,
        SUM(health_and_dental)               AS health_and_dental_usd,
        SUM(other_benefits)                  AS other_benefits_usd,
        SUM(total_benefits)                  AS total_benefits_usd,
        SUM(total_compensation)              AS total_compensation_usd
    FROM fiscal
    GROUP BY year, department_code
),

-- Per-employee totals within a department-year → exact median.
per_employee_dept AS (
    SELECT
        year,
        department_code,
        employee_identifier,
        SUM(total_compensation) AS employee_dept_comp
    FROM fiscal
    GROUP BY year, department_code, employee_identifier
),

dept_medians AS (
    SELECT DISTINCT
        year,
        department_code,
        PERCENTILE_CONT(CAST(employee_dept_comp AS FLOAT64), 0.5)
            OVER (PARTITION BY year, department_code) AS median_total_comp_usd
    FROM per_employee_dept
),

provenance AS (
    SELECT DISTINCT
        dataset_id,
        dataset_name,
        dataset_page_url,
        attribution,
        rows_updated_at
    FROM {{ ref('core_us_sf_source_catalog') }}
    WHERE source_id = 'sf_employee_comp'
)

SELECT
    d.year                       AS fiscal_year,
    'Fiscal'                     AS year_type,
    d.department_code,
    c.department,
    c.organization_group_code,
    c.organization_group,
    d.salaries_usd,
    d.overtime_usd,
    d.other_salaries_usd,
    d.total_salary_usd,
    d.retirement_usd,
    d.health_and_dental_usd,
    d.other_benefits_usd,
    d.total_benefits_usd,
    d.total_compensation_usd,
    SAFE_DIVIDE(d.overtime_usd, d.total_compensation_usd)  AS ot_share_of_comp,
    d.n_employees,
    m.median_total_comp_usd,
    pr.dataset_id                AS source_dataset_id,
    pr.dataset_name              AS source_name,
    pr.dataset_page_url          AS source_url,
    pr.attribution               AS source_attribution,
    pr.rows_updated_at           AS source_rows_updated_at,
    'USD'                        AS unit
FROM dept_year d
INNER JOIN canonical_dept c USING (department_code)
INNER JOIN dept_medians m USING (year, department_code)
CROSS JOIN provenance pr
-- Publication threshold (dial B): never publish a department-year cell
-- covering fewer than 5 people.
WHERE d.n_employees >= 5
