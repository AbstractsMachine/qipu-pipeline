-- =============================================================================
-- Mart: City employees paid over $75,000, one row per fiscal year 2008→.
--
-- What the schedule is: the SOFI lists every employee whose remuneration
-- exceeded $75,000 that year (BC Financial Information Act). The threshold is
-- nominal — it has not moved since 2008 — so the count grows with wages as
-- well as with hiring; the page says so. No police department appears among
-- the schedule's departments (measured 2008–2025).
-- Aggregates only: no row carries a name, and no statistic is a single
-- person's pay (no max) — privacy doctrine, stg_ca_vancouver_remuneration.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH cat AS (
    SELECT dataset_title, dataset_page_url, license_title, rows_updated_at
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
    WHERE source_id = 'employee_remuneration'
)

SELECT
    r.fiscal_year,
    COUNT(*)                                              AS n_people,
    SUM(r.remuneration_cad)                               AS remuneration_total_cad,
    SUM(r.expenses_cad)                                   AS expenses_total_cad,
    APPROX_QUANTILES(r.remuneration_cad, 100)[OFFSET(25)] AS p25_cad,
    APPROX_QUANTILES(r.remuneration_cad, 100)[OFFSET(50)] AS median_cad,
    APPROX_QUANTILES(r.remuneration_cad, 100)[OFFSET(75)] AS p75_cad,
    APPROX_QUANTILES(r.remuneration_cad, 100)[OFFSET(90)] AS p90_cad,
    COUNT(DISTINCT r.department)                          AS n_departments,
    COUNT(DISTINCT r.title)                               AS n_titles,
    ANY_VALUE(cat.dataset_title)                          AS source_name,
    ANY_VALUE(cat.dataset_page_url)                       AS source_url,
    ANY_VALUE(cat.license_title)                          AS source_license,
    ANY_VALUE(cat.rows_updated_at)                        AS source_as_of
FROM {{ ref('core_ca_vancouver_remuneration') }} r
CROSS JOIN cat
GROUP BY 1
