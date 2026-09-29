-- =============================================================================
-- Mart: SF payroll by department × job family × fiscal year — the drill
--       grain, with the dial-B small-cell rule applied IN the mart
--
-- Sources: core_us_sf_comp (year_type = 'Fiscal'), core_us_sf_comp (family_code)
--          (103 junk job codes → real families, in-session seed),
--          int_us_sf_job_families (60 family codes → 16 display
--          families, in-session seed), core_us_sf_source_catalog (provenance).
-- Grain:  department_code × job_family_code (effective) × fiscal year —
--         plus one pooled "_POOLED" row per department-year where small
--         cells could be pooled. ~5-6k rows over 13 years.
--
-- FAMILY DIMENSION. The source's native job_family is 100% populated
-- (59 codes — no AI classification needed, block study §3). Two fixes on
-- top, both provenance-flagged seeds:
--   1. reclass: rows whose native family is junk ("Untitled" 0000 /
--      "Unassigned") take the family assigned by seed_us_sf_job_reclass
--      (court xxC codes → SF Superior Court, mayoral staff → Management,
--      commissioners → synthetic ELEC…). Never overrides a real value;
--      is_reclassified marks affected cells.
--   2. display_family: 16 citizen-readable groups from
--      seed_us_sf_job_family_display. An unmapped future family code
--      falls back to its own native label (self-labeling, visible) and
--      trips the accepted_values test — extend the seed, don't hide it.
--
-- PRIVACY (dial B, approved by Daniel — measured cost 1.25% of FY2025 $,
-- 1.27% all-years): a cell is published only with n ≥ 5 distinct
-- employees. Sub-threshold cells are pooled per department-year into ONE
-- visible "Other roles" row (family_code '_POOLED', n_pooled_families
-- exposed — zero silent suppression). If the pool itself has n < 5 it is
-- NOT published either (defeats subtraction-recovery of a near-individual
-- cell): those dollars stay in the department totals
-- (mart_us_sf_payroll_by_dept_year) with no family row — asserted by
-- tests/us/assert_us_sf_payroll_family_cells_reconcile.sql. Departments
-- below the dept-level threshold (Law Library…) get no family rows at all.
-- =============================================================================

WITH fiscal AS (
    SELECT *
    FROM {{ ref('core_us_sf_comp') }}
    WHERE year_type = 'Fiscal'
      AND department_code IS NOT NULL
),

-- family_code / is_reclassified_row come from core_us_sf_comp (the manual
-- reclass of empty portal families is applied there, row-level).
rows_with_family AS (
    SELECT *
    FROM fiscal
),

display AS (
    SELECT job_family_code, canonical_label, display_family
    FROM {{ ref('int_us_sf_job_families') }}
),

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

-- Department-years that are published at dept level (n ≥ 5): family rows
-- may only exist inside them.
published_dept_years AS (
    SELECT year, department_code
    FROM fiscal
    GROUP BY year, department_code
    HAVING COUNT(DISTINCT employee_identifier) >= 5
),

cells AS (
    SELECT
        r.year,
        r.department_code,
        r.family_code,
        COUNT(DISTINCT r.employee_identifier)  AS n_employees,
        SUM(r.salaries)                        AS salaries_usd,
        SUM(r.overtime)                        AS overtime_usd,
        SUM(r.other_salaries)                  AS other_salaries_usd,
        SUM(r.total_benefits)                  AS total_benefits_usd,
        SUM(r.total_compensation)              AS total_compensation_usd,
        LOGICAL_OR(r.is_reclassified_row)      AS is_reclassified
    FROM rows_with_family r
    INNER JOIN published_dept_years p
        ON p.year = r.year AND p.department_code = r.department_code
    GROUP BY r.year, r.department_code, r.family_code
),

published_cells AS (
    SELECT * FROM cells WHERE n_employees >= 5
),

-- Pool the sub-threshold cells per department-year. n is recomputed on
-- distinct employees across the pooled cells (an employee can sit in two
-- small cells of the same department).
pooled AS (
    SELECT
        r.year,
        r.department_code,
        '_POOLED'                              AS family_code,
        COUNT(DISTINCT r.employee_identifier)  AS n_employees,
        SUM(r.salaries)                        AS salaries_usd,
        SUM(r.overtime)                        AS overtime_usd,
        SUM(r.other_salaries)                  AS other_salaries_usd,
        SUM(r.total_benefits)                  AS total_benefits_usd,
        SUM(r.total_compensation)              AS total_compensation_usd,
        LOGICAL_OR(r.is_reclassified_row)      AS is_reclassified,
        COUNT(DISTINCT r.family_code)          AS n_pooled_families
    FROM rows_with_family r
    INNER JOIN cells c
        ON c.year = r.year
       AND c.department_code = r.department_code
       AND c.family_code = r.family_code
       AND c.n_employees < 5
    GROUP BY r.year, r.department_code
    -- The pool must itself clear the threshold, or it is folded into the
    -- department total (no row at all).
    HAVING COUNT(DISTINCT r.employee_identifier) >= 5
),

unioned AS (
    SELECT
        year, department_code, family_code, n_employees,
        salaries_usd, overtime_usd, other_salaries_usd,
        total_benefits_usd, total_compensation_usd,
        is_reclassified,
        CAST(NULL AS INT64) AS n_pooled_families,
        FALSE               AS is_pooled
    FROM published_cells
    UNION ALL
    SELECT
        year, department_code, family_code, n_employees,
        salaries_usd, overtime_usd, other_salaries_usd,
        total_benefits_usd, total_compensation_usd,
        is_reclassified,
        n_pooled_families,
        TRUE                AS is_pooled
    FROM pooled
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
    u.year                       AS fiscal_year,
    'Fiscal'                     AS year_type,
    u.department_code,
    c.department,
    c.organization_group_code,
    c.organization_group,
    u.family_code,
    CASE
        WHEN u.is_pooled THEN 'Other roles'
        ELSE COALESCE(d.canonical_label, u.family_code)
    END                          AS family_label,
    CASE
        WHEN u.is_pooled THEN 'Other roles'
        ELSE COALESCE(d.display_family, d.canonical_label, u.family_code)
    END                          AS display_family,
    u.is_pooled,
    u.n_pooled_families,
    u.is_reclassified,
    u.n_employees,
    u.salaries_usd,
    u.overtime_usd,
    u.other_salaries_usd,
    u.total_benefits_usd,
    u.total_compensation_usd,
    pr.dataset_id                AS source_dataset_id,
    pr.dataset_name              AS source_name,
    pr.dataset_page_url          AS source_url,
    pr.attribution               AS source_attribution,
    pr.rows_updated_at           AS source_rows_updated_at,
    'USD'                        AS unit
FROM unioned u
INNER JOIN canonical_dept c USING (department_code)
LEFT JOIN display d
    ON d.job_family_code = u.family_code
CROSS JOIN provenance pr
