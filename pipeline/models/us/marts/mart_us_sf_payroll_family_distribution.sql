-- =============================================================================
-- Mart: SF payroll — what KIND of work sits at each pay level
--       (fiscal year × display job family: percentiles + $25k histogram)
--
-- Sources: int_us_sf_comp_employee_year (person × year totals — the unit of
--          analysis for every distribution statement on the site),
--          core_us_sf_comp (job codes, to attribute a person to a family),
--          int_us_sf_job_reclass / int_us_sf_job_families (the same
--          two provenance-flagged seeds the family marts use),
--          core_us_sf_source_catalog (provenance).
-- Grain:  fiscal year × display_family (the 16 citizen-readable groups the
--         page names — percentiles CANNOT be rolled up from a finer grain,
--         so they are computed here at the grain the UI reads), plus one
--         '_OTHER' row per fiscal year holding the cells too small to publish.
--
-- WHY THIS MART. mart_us_sf_payroll_distribution answers "how is city pay
-- spread?" but not "who is where in that spread?" — the histogram is a wall
-- of anonymous bars. This mart carries the same person-grain distribution
-- CUT BY job family, so the page can answer both:
--   1. the pay ladder — each family's p25 / median / p75, sorted;
--   2. bucket composition — for a $25k band, which families are in it.
--
-- PRIMARY FAMILY. A person can be paid under several job codes in a year.
-- They are counted ONCE, under the family that paid them the most
-- (deterministic tie-break on family_code) — the same rule
-- mart_us_sf_payroll_high_earner_titles uses for primary title. Their WHOLE
-- annual compensation is attributed to that family, so
--   Σ n_people_primary over families = citywide n_employees,
--   Σ histogram cells over families = the citywide histogram
-- exactly (tests/us/assert_us_sf_payroll_family_distribution_reconciles.sql).
-- This is deliberately NOT the same measure as n_employees in
-- mart_us_sf_payroll_by_family_year, which counts a dual-role person in both
-- families: that mart splits dollars, this one splits people.
--
-- PRIVACY. Percentile rows are published only for families with ≥ 5 people
-- (dial B). Histogram cells are counts with no dollar amount attached, but a
-- named cell of 1 would still place one person in a $25k band, so named
-- cells under 5 are pooled per fiscal year into the '_OTHER' row —
-- count-only, naming no family. The pooled row itself is NOT thresholded:
-- it is arithmetically derivable from what is already public (the citywide
-- bucket count in mart_us_sf_payroll_distribution minus the named cells of
-- that bucket), so suppressing it would hide nothing while breaking the
-- Σ = citywide identity the test relies on. Nothing is dropped.
-- =============================================================================

WITH fiscal AS (
    SELECT *
    FROM {{ ref('core_us_sf_comp') }}
    WHERE year_type = 'Fiscal'
),

-- Person × year totals — identical to what the citywide distribution mart
-- describes, so the two files can be read side by side.
person AS (
    SELECT
        year,
        employee_identifier,
        CAST(total_compensation AS FLOAT64) AS comp
    FROM {{ ref('int_us_sf_comp_employee_year') }}
    WHERE year_type = 'Fiscal'
),

reclass AS (
    SELECT job_code, reclass_family_code
    FROM {{ ref('int_us_sf_job_reclass') }}
),

display AS (
    SELECT job_family_code, canonical_label, display_family
    FROM {{ ref('int_us_sf_job_families') }}
),

-- Effective family per source row: reclass fills junk codes only, never
-- overrides a real value (same rule as mart_us_sf_payroll_by_family_year).
-- Resolved straight to the display family — this mart's whole grain.
rows_with_family AS (
    SELECT
        f.year,
        f.employee_identifier,
        f.total_compensation,
        COALESCE(d.display_family, d.canonical_label, eff.family_code) AS display_family
    FROM fiscal f
    LEFT JOIN reclass r
        ON r.job_code = f.job_code
    CROSS JOIN UNNEST([STRUCT(
        CASE
            WHEN f.job_family_code IN ('0000', '__UNASSIGNED__')
                 AND r.reclass_family_code IS NOT NULL
                THEN r.reclass_family_code
            ELSE f.job_family_code
        END AS family_code
    )]) AS eff
    LEFT JOIN display d
        ON d.job_family_code = eff.family_code
),

per_emp_family AS (
    SELECT
        year,
        employee_identifier,
        display_family,
        SUM(total_compensation) AS comp_in_family
    FROM rows_with_family
    GROUP BY year, employee_identifier, display_family
),

primary_family AS (
    SELECT year, employee_identifier, display_family
    FROM per_emp_family
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY year, employee_identifier
        ORDER BY comp_in_family DESC, display_family
    ) = 1
),

-- One row per person-year, carrying their full annual compensation and the
-- family it is attributed to.
attributed AS (
    SELECT
        p.year,
        pf.display_family,
        p.comp
    FROM person p
    INNER JOIN primary_family pf
        ON pf.year = p.year
       AND pf.employee_identifier = p.employee_identifier
),

family_stats AS (
    SELECT DISTINCT
        year,
        display_family,
        COUNT(*)      OVER w AS n_people_primary,
        AVG(comp)     OVER w AS mean_usd,
        SUM(comp)     OVER w AS total_comp_usd,
        PERCENTILE_CONT(comp, 0.25) OVER w AS p25,
        PERCENTILE_CONT(comp, 0.50) OVER w AS p50,
        PERCENTILE_CONT(comp, 0.75) OVER w AS p75,
        PERCENTILE_CONT(comp, 0.90) OVER w AS p90
    FROM attributed
    WINDOW w AS (PARTITION BY year, display_family)
),

published_families AS (
    SELECT * FROM family_stats WHERE n_people_primary >= 5
),

-- $25k buckets, capped at the same 20th bucket (>= $500k) the citywide
-- histogram uses so the two line up bucket for bucket.
bucketed AS (
    SELECT
        year,
        display_family,
        CAST(LEAST(FLOOR(GREATEST(comp, 0) / 25000), 20) AS INT64) AS bucket_idx,
        COUNT(*) AS n
    FROM attributed
    GROUP BY year, display_family, bucket_idx
),

-- A cell survives only if its family is publishable AND the cell itself
-- clears the threshold.
published_cells AS (
    SELECT b.year, b.display_family, b.bucket_idx, b.n
    FROM bucketed b
    INNER JOIN published_families f
        ON f.year = b.year AND f.display_family = b.display_family
    WHERE b.n >= 5
),

pooled_cells AS (
    SELECT
        b.year,
        '_OTHER'      AS display_family,
        b.bucket_idx,
        SUM(b.n)      AS n
    FROM bucketed b
    LEFT JOIN published_cells p
        ON p.year = b.year
       AND p.display_family = b.display_family
       AND p.bucket_idx = b.bucket_idx
    WHERE p.display_family IS NULL
    GROUP BY b.year, b.bucket_idx
),

all_cells AS (
    SELECT * FROM published_cells
    UNION ALL
    SELECT * FROM pooled_cells
),

histograms AS (
    SELECT
        year,
        display_family,
        SUM(n) AS n_in_histogram,
        ARRAY_AGG(
            STRUCT(
                bucket_idx * 25000                                       AS bucket_floor_usd,
                IF(bucket_idx = 20, CAST(NULL AS INT64),
                   (bucket_idx + 1) * 25000)                             AS bucket_ceiling_usd,
                n                                                        AS n_employees
            )
            ORDER BY bucket_idx
        ) AS histogram
    FROM all_cells
    GROUP BY year, display_family
),

-- '_OTHER' has no percentile row (it is a pool of unrelated families); it
-- carries counts only.
combined AS (
    SELECT
        h.year,
        h.display_family,
        f.n_people_primary,
        f.total_comp_usd,
        f.mean_usd,
        f.p25,
        f.p50,
        f.p75,
        f.p90,
        h.n_in_histogram,
        h.histogram,
        h.display_family = '_OTHER' AS is_pooled
    FROM histograms h
    LEFT JOIN published_families f
        ON f.year = h.year AND f.display_family = h.display_family
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
    c.year                       AS fiscal_year,
    'Fiscal'                     AS year_type,
    IF(c.is_pooled, 'Other roles', c.display_family) AS display_family,
    c.is_pooled,
    c.n_people_primary,
    c.n_in_histogram,
    c.total_comp_usd,
    c.mean_usd                   AS mean_total_comp_usd,
    c.p25                        AS p25_usd,
    c.p50                        AS p50_usd,
    c.p75                        AS p75_usd,
    c.p90                        AS p90_usd,
    c.histogram,
    25000                        AS bucket_width_usd,
    pr.dataset_id                AS source_dataset_id,
    pr.dataset_name              AS source_name,
    pr.dataset_page_url          AS source_url,
    pr.attribution               AS source_attribution,
    pr.rows_updated_at           AS source_rows_updated_at,
    'USD'                        AS unit
FROM combined c
CROSS JOIN provenance pr
