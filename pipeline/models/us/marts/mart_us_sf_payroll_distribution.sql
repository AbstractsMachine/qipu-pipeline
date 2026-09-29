-- =============================================================================
-- Mart: SF payroll distribution per fiscal year — percentiles, threshold
--       counts and a $25k-bucket histogram (citywide only, v1)
--
-- Sources: int_us_sf_comp_employee_year (person grain — distribution
--          statements are per-person), core_us_sf_source_catalog (provenance).
-- Grain:  fiscal year, 2013-2025 (histogram as an ARRAY<STRUCT> column).
--
-- Percentiles are EXACT (PERCENTILE_CONT). p10 IS NOT PUBLISHED — the
-- study measured it as part-timer pollution (FY2025: 10.3% of employees
-- under $25k are part-time/partial-year), an invitation to "poverty
-- wages" misreads. The published floor is p25; the low histogram bump is
-- annotated in the UI instead.
--
-- Histogram: 20 buckets of $25,000 from $0 to $500k, plus
-- n_at_or_above_500k so that Σ bucket + top == n_employees exactly
-- (tests/us/assert_us_sf_payroll_distribution_identity.sql). 235
-- employee-years across 13 years have NEGATIVE net comp (adjustment
-- rows); they are counted in the $0-25k bucket for the histogram
-- (GREATEST(comp, 0)) and exposed via n_negative_comp. Sparse top-tail
-- buckets (n < 5, only 2013-2016) are merged into an open top bucket at
-- EXPORT time — the mart keeps raw buckets, the export applies the
-- publication rule and the validator asserts it.
--
-- Threshold counts (>$200k…>$500k) are citywide COUNT-ONLY disclosures
-- (no dollar aggregate attached) and are published exactly, including
-- values under 5 (FY2013 has exactly one employee above $400k) — the
-- méthode section states this choice; every dollar-carrying cell in the
-- payroll exports covers ≥ 5 people.
-- =============================================================================

WITH per_employee AS (
    SELECT *
    FROM {{ ref('int_us_sf_comp_employee_year') }}
    WHERE year_type = 'Fiscal'
),

percentiles AS (
    SELECT DISTINCT
        year,
        PERCENTILE_CONT(CAST(total_compensation AS FLOAT64), 0.25) OVER (PARTITION BY year) AS p25,
        PERCENTILE_CONT(CAST(total_compensation AS FLOAT64), 0.50) OVER (PARTITION BY year) AS p50,
        PERCENTILE_CONT(CAST(total_compensation AS FLOAT64), 0.75) OVER (PARTITION BY year) AS p75,
        PERCENTILE_CONT(CAST(total_compensation AS FLOAT64), 0.90) OVER (PARTITION BY year) AS p90,
        PERCENTILE_CONT(CAST(total_compensation AS FLOAT64), 0.99) OVER (PARTITION BY year) AS p99
    FROM per_employee
),

counts AS (
    SELECT
        year,
        COUNT(*)                                   AS n_employees,
        COUNTIF(total_compensation > 200000)       AS n_above_200k,
        COUNTIF(total_compensation > 300000)       AS n_above_300k,
        COUNTIF(total_compensation > 400000)       AS n_above_400k,
        COUNTIF(total_compensation > 500000)       AS n_above_500k,
        COUNTIF(total_compensation >= 500000)      AS n_at_or_above_500k,
        COUNTIF(total_compensation < 0)            AS n_negative_comp
    FROM per_employee
    GROUP BY year
),

bucketed AS (
    SELECT
        year,
        CAST(LEAST(FLOOR(GREATEST(CAST(total_compensation AS FLOAT64), 0) / 25000), 20) AS INT64) AS bucket_idx,
        COUNT(*) AS n
    FROM per_employee
    GROUP BY year, bucket_idx
),

histograms AS (
    SELECT
        year,
        ARRAY_AGG(
            STRUCT(
                bucket_idx * 25000        AS bucket_floor_usd,
                (bucket_idx + 1) * 25000  AS bucket_ceiling_usd,
                n                         AS n_employees
            )
            ORDER BY bucket_idx
        ) AS histogram_under_500k
    FROM bucketed
    WHERE bucket_idx < 20
    GROUP BY year
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
    c.n_employees,
    p.p25                        AS p25_usd,
    p.p50                        AS p50_usd,
    p.p75                        AS p75_usd,
    p.p90                        AS p90_usd,
    p.p99                        AS p99_usd,
    c.n_above_200k,
    c.n_above_300k,
    c.n_above_400k,
    c.n_above_500k,
    c.n_at_or_above_500k,
    c.n_negative_comp,
    h.histogram_under_500k,
    25000                        AS bucket_width_usd,
    pr.dataset_id                AS source_dataset_id,
    pr.dataset_name              AS source_name,
    pr.dataset_page_url          AS source_url,
    pr.attribution               AS source_attribution,
    pr.rows_updated_at           AS source_rows_updated_at,
    'USD'                        AS unit
FROM counts c
INNER JOIN percentiles p USING (year)
INNER JOIN histograms h USING (year)
CROSS JOIN provenance pr
