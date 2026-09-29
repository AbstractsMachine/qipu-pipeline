-- =============================================================================
-- Core: SF Employee Compensation OBT — row-level comp records, BOTH year types
--
-- Source: stg_us_sf_comp (~1.1M rows)
-- Grain:  pseudonymous employee_identifier × year × year_type × job × dept.
--
-- year_type ('Calendar' | 'Fiscal') is DELIBERATELY kept in core with the
-- field exposed — the same compensation appears under both accountings and
-- filtering is mart business (mart_us_sf_comp_by_year takes 'Fiscal').
-- Anything summing this table without a year_type predicate double-counts
-- (docs/us/API-RECON.md §A.5 — the dataset's #1 trap, tested in
-- tests/us/assert_us_sf_comp_year_type_split.sql).
-- =============================================================================

WITH comp AS (
    SELECT *
    FROM {{ ref('stg_us_sf_comp') }}
),

-- Manual reclassification of job codes whose portal family is empty
-- ('0000' / '__UNASSIGNED__') — seed, display only.
reclass AS (
    SELECT job_code, reclass_family_code, reclass_family
    FROM {{ ref('stg_us_sf_job_reclass') }}
),

-- Display label per effective family code — seed, display only.
display AS (
    SELECT job_family_code, canonical_label, display_family
    FROM {{ ref('stg_us_sf_job_family_display') }}
),

with_family AS (
    SELECT
        c.*,
        r.reclass_family_code,
        r.reclass_family,
        -- effective family: the portal family unless it is empty and a
        -- manual reclassification exists for the job code
        CASE
            WHEN c.job_family_code IN ('0000', '__UNASSIGNED__')
                 AND r.reclass_family_code IS NOT NULL
                THEN r.reclass_family_code
            ELSE c.job_family_code
        END AS family_code,
        (c.job_family_code IN ('0000', '__UNASSIGNED__')
         AND r.reclass_family_code IS NOT NULL) AS is_reclassified_row
    FROM comp c
    LEFT JOIN reclass r ON r.job_code = c.job_code
)

SELECT
    f.*,
    d.canonical_label                  AS family_canonical_label,
    d.display_family                   AS family_display
FROM with_family f
LEFT JOIN display d ON d.job_family_code = f.family_code
