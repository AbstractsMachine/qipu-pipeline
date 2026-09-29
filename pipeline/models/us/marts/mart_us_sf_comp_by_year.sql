-- =============================================================================
-- Mart: SF employee compensation by fiscal year
--
-- Sources: core_us_sf_comp (FILTERED to year_type = 'Fiscal' here — the
--          mart is where the Calendar/Fiscal choice is made, per the
--          core-keeps-both rule), int_us_sf_comp_employee_year (person
--          grain — median and the OT-exceeds-salary counters are
--          per-person statements), core_us_sf_population (per-resident,
--          Census years 2020-2025), core_us_sf_source_catalog (provenance).
-- Grain:  fiscal year, 2013-2025.
--
-- n_employees = distinct pseudonymous employee identifiers (headcount-ish,
-- includes part-year and part-time staff — NOT FTE). median/avg per-employee
-- comp are computed on per-employee annual totals from the intermediate
-- (an employee can have several rows across jobs/departments); the median
-- is EXACT (PERCENTILE_CONT), not an approximate sketch — it is the page's
-- hero number and must be deterministic.
--
-- n_ot_exceeds_salary_floored uses the documented $1,000 salary floor
-- (int_us_sf_comp_employee_year header: the FY2019 naive count is an
-- artifact of job-change rows with ≤$1k salaries). The floor value is
-- exposed as a column so the export/UI reads it from data, never hardcodes.
--
-- per_resident_usd only exists where a same-year Census estimate exists
-- (2020-2025); SF FY N ends Jun 30 of year N, so the July 1 estimate of
-- year N is the FY-end population (same rule as mart_us_sf_budget_by_year).
-- =============================================================================

WITH fiscal AS (
    SELECT *
    FROM {{ ref('core_us_sf_comp') }}
    WHERE year_type = 'Fiscal'
),

per_employee AS (
    SELECT *
    FROM {{ ref('int_us_sf_comp_employee_year') }}
    WHERE year_type = 'Fiscal'
),

medians AS (
    SELECT DISTINCT
        year,
        PERCENTILE_CONT(CAST(total_compensation AS FLOAT64), 0.5)
            OVER (PARTITION BY year) AS median_total_comp_usd
    FROM per_employee
),

per_employee_stats AS (
    SELECT
        year,
        COUNT(*)                                  AS n_employees,
        AVG(total_compensation)                   AS avg_total_comp_usd,
        COUNTIF(ot_exceeds_salary_naive)          AS n_ot_exceeds_salary_naive,
        COUNTIF(ot_exceeds_salary_floored)        AS n_ot_exceeds_salary_floored
    FROM per_employee
    GROUP BY year
),

totals AS (
    SELECT
        year,
        SUM(salaries)            AS salaries_usd,
        SUM(overtime)            AS overtime_usd,
        SUM(other_salaries)      AS other_salaries_usd,
        SUM(total_salary)        AS total_salary_usd,
        SUM(retirement)          AS retirement_usd,
        SUM(health_and_dental)   AS health_and_dental_usd,
        SUM(other_benefits)      AS other_benefits_usd,
        SUM(total_benefits)      AS total_benefits_usd,
        SUM(total_compensation)  AS total_compensation_usd,
        COUNT(*)                 AS n_rows
    FROM fiscal
    GROUP BY year
),

pop AS (
    SELECT year, as_of_date, population, source, source_url
    FROM {{ ref('core_us_sf_population') }}
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
    t.year                      AS fiscal_year,
    'Fiscal'                    AS year_type,
    t.salaries_usd,
    t.overtime_usd,
    t.other_salaries_usd,
    t.total_salary_usd,
    t.retirement_usd,
    t.health_and_dental_usd,
    t.other_benefits_usd,
    t.total_benefits_usd,
    t.total_compensation_usd,
    SAFE_DIVIDE(t.overtime_usd, t.total_compensation_usd)  AS ot_share_of_comp,
    t.n_rows,
    s.n_employees,
    s.avg_total_comp_usd,
    m.median_total_comp_usd,
    s.n_ot_exceeds_salary_naive,
    s.n_ot_exceeds_salary_floored,
    1000                        AS ot_salary_floor_usd,
    SAFE_DIVIDE(t.total_compensation_usd, p.population)     AS per_resident_usd,
    SAFE_DIVIDE(s.n_employees * 1000, p.population)         AS employees_per_1k_residents,
    p.population,
    p.year                      AS population_year,
    p.as_of_date                AS population_as_of,
    p.source                    AS population_source,
    p.source_url                AS population_source_url,
    pr.dataset_id               AS source_dataset_id,
    pr.dataset_name             AS source_name,
    pr.dataset_page_url         AS source_url,
    pr.attribution              AS source_attribution,
    pr.rows_updated_at          AS source_rows_updated_at,
    'USD'                       AS unit
FROM totals t
INNER JOIN per_employee_stats s USING (year)
INNER JOIN medians m USING (year)
LEFT JOIN pop p
    ON p.year = t.year
CROSS JOIN provenance pr
