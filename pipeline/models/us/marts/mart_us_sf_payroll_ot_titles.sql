-- =============================================================================
-- Mart: top overtime job titles, latest fiscal year — title-level context
--       for the overtime lens
--
-- Sources: core_us_sf_comp (year_type = 'Fiscal', latest year),
--          int_us_sf_job_reclass + int_us_sf_job_families (family
--          context labels), core_us_sf_source_catalog (provenance).
-- Grain:  job_code, top 10 by overtime dollars in the latest fiscal year.
--
-- Title-level detail is fine HERE because the list is filtered to titles
-- with ≥ 100 employees citywide (block study §2: every top-OT title
-- clears it by a wide margin — Transit Operator 2,618, Sergeant 3 428,
-- minimum in the FY2025 top-10 is 203). A title that ever dipped below
-- 100 employees would drop off the list rather than ship a small cell;
-- the méthode section states the rule. Within a year job_code ↔ title is
-- 1:1 (study §3), so ANY_VALUE(job) is deterministic.
-- =============================================================================

WITH fiscal AS (
    SELECT *
    FROM {{ ref('core_us_sf_comp') }}
    WHERE year_type = 'Fiscal'
),

latest AS (
    SELECT MAX(year) AS year FROM fiscal
),

reclass AS (
    SELECT job_code, reclass_family_code
    FROM {{ ref('int_us_sf_job_reclass') }}
),

display AS (
    SELECT job_family_code, canonical_label, display_family
    FROM {{ ref('int_us_sf_job_families') }}
),

by_title AS (
    SELECT
        f.year,
        f.job_code,
        ANY_VALUE(f.job)                                   AS job_title,
        CASE
            WHEN ANY_VALUE(f.job_family_code) IN ('0000', '__UNASSIGNED__')
                 AND ANY_VALUE(r.reclass_family_code) IS NOT NULL
                THEN ANY_VALUE(r.reclass_family_code)
            ELSE ANY_VALUE(f.job_family_code)
        END                                                AS family_code,
        COUNT(DISTINCT f.employee_identifier)              AS n_employees,
        COUNT(DISTINCT IF(f.overtime > 0, f.employee_identifier, NULL)) AS n_ot_earners,
        SUM(f.overtime)                                    AS overtime_usd,
        SUM(f.total_compensation)                          AS total_compensation_usd
    FROM fiscal f
    INNER JOIN latest l ON f.year = l.year
    LEFT JOIN reclass r ON r.job_code = f.job_code
    GROUP BY f.year, f.job_code
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
    b.year                       AS fiscal_year,
    'Fiscal'                     AS year_type,
    b.job_code,
    b.job_title,
    b.family_code,
    COALESCE(d.display_family, d.canonical_label, b.family_code) AS display_family,
    b.n_employees,
    b.n_ot_earners,
    b.overtime_usd,
    SAFE_DIVIDE(b.overtime_usd, b.n_ot_earners)  AS avg_ot_per_ot_earner_usd,
    b.total_compensation_usd,
    pr.dataset_id                AS source_dataset_id,
    pr.dataset_name              AS source_name,
    pr.dataset_page_url          AS source_url,
    pr.attribution               AS source_attribution,
    pr.rows_updated_at           AS source_rows_updated_at,
    'USD'                        AS unit
FROM by_title b
LEFT JOIN display d
    ON d.job_family_code = b.family_code
CROSS JOIN provenance pr
WHERE b.n_employees >= 100
QUALIFY ROW_NUMBER() OVER (ORDER BY b.overtime_usd DESC, b.job_code) <= 10
