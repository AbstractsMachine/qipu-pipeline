-- =============================================================================
-- Mart: composition of the >$400k group, latest fiscal year — COUNT-ONLY
--
-- Sources: core_us_sf_comp + int_us_sf_comp_employee_year (Fiscal),
--          int_us_sf_job_reclass / int_us_sf_job_families (family
--          context), core_us_sf_source_catalog (provenance).
-- Grain:  job title (primary title per person) among employees whose
--         TOTAL annual compensation exceeds $400k — top titles with
--         n ≥ 5, plus one remainder row. NO dollar columns: this mart
--         exists so the page's "public-safety supervisors and
--         physicians" framing is pipeline data, not prose (zero-hardcode
--         rule). Counts attach no amounts beyond ">$400k".
--
-- A person can hold several titles in a year; they are counted once,
-- under the title that paid them the most (deterministic tie-break on
-- job_code).
-- =============================================================================

WITH latest AS (
    SELECT MAX(year) AS year
    FROM {{ ref('core_us_sf_comp') }}
    WHERE year_type = 'Fiscal'
),

high_earners AS (
    SELECT i.year, i.employee_identifier
    FROM {{ ref('int_us_sf_comp_employee_year') }} i
    INNER JOIN latest l ON i.year = l.year
    WHERE i.year_type = 'Fiscal'
      AND i.total_compensation > 400000
),

per_emp_title AS (
    SELECT
        f.year,
        f.employee_identifier,
        f.job_code,
        ANY_VALUE(f.job)             AS job_title,
        ANY_VALUE(f.job_family_code) AS job_family_code,
        SUM(f.total_compensation)    AS comp_usd
    FROM {{ ref('core_us_sf_comp') }} f
    INNER JOIN latest l ON f.year = l.year
    WHERE f.year_type = 'Fiscal'
    GROUP BY f.year, f.employee_identifier, f.job_code
),

primary_title AS (
    SELECT *
    FROM per_emp_title
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY year, employee_identifier
        ORDER BY comp_usd DESC, job_code
    ) = 1
),

high_by_title AS (
    SELECT
        p.year,
        p.job_code,
        ANY_VALUE(p.job_title)        AS job_title,
        ANY_VALUE(p.job_family_code)  AS job_family_code,
        COUNT(*)                      AS n_employees
    FROM primary_title p
    INNER JOIN high_earners h
        ON h.year = p.year
       AND h.employee_identifier = p.employee_identifier
    GROUP BY p.year, p.job_code
),

reclass AS (
    SELECT job_code, reclass_family_code
    FROM {{ ref('int_us_sf_job_reclass') }}
),

display AS (
    SELECT job_family_code, canonical_label, display_family
    FROM {{ ref('int_us_sf_job_families') }}
),

top_titles AS (
    SELECT
        b.year,
        b.job_code,
        b.job_title,
        COALESCE(d.display_family, d.canonical_label,
                 b.job_family_code)  AS display_family,
        b.n_employees,
        FALSE                        AS is_remainder
    FROM high_by_title b
    LEFT JOIN reclass r
        ON r.job_code = b.job_code
    LEFT JOIN display d
        ON d.job_family_code = CASE
            WHEN b.job_family_code IN ('0000', '__UNASSIGNED__')
                 AND r.reclass_family_code IS NOT NULL
                THEN r.reclass_family_code
            ELSE b.job_family_code
        END
    WHERE b.n_employees >= 5
    QUALIFY ROW_NUMBER() OVER (ORDER BY b.n_employees DESC, b.job_code) <= 10
),

remainder AS (
    SELECT
        b.year,
        CAST(NULL AS STRING)  AS job_code,
        'Other titles'        AS job_title,
        CAST(NULL AS STRING)  AS display_family,
        SUM(b.n_employees) - (SELECT SUM(n_employees) FROM top_titles) AS n_employees,
        TRUE                  AS is_remainder
    FROM high_by_title b
    GROUP BY b.year
),

unioned AS (
    SELECT * FROM top_titles
    UNION ALL
    SELECT * FROM remainder WHERE n_employees > 0
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
    400000                       AS threshold_usd,
    u.job_code,
    u.job_title,
    u.display_family,
    u.n_employees,
    u.is_remainder,
    pr.dataset_id                AS source_dataset_id,
    pr.dataset_name              AS source_name,
    pr.dataset_page_url          AS source_url,
    pr.attribution               AS source_attribution,
    pr.rows_updated_at           AS source_rows_updated_at
FROM unioned u
CROSS JOIN provenance pr
