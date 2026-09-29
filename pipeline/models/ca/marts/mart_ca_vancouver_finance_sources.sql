-- =============================================================================
-- Mart: every SOFI document the finance pages read, one row per PDF — the
-- City's original URL, the Internet Archive capture read, its SHA-256 — with
-- what each document supplies to the site and the misprints found in it.
--
-- used_for: 'suppliers' / 'grants' (schedules parsed from it) and
--           'review:<table> <years>' (five-year-review tables whose years are
--           read from it after the latest-print rule and the misprint seed).
-- misprints: rows of seed_ca_vancouver_sofi_review_misprints for this report.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH docs AS (
    SELECT * FROM {{ ref('stg_ca_vancouver_sofi_documents') }}
),

schedules AS (
    SELECT DISTINCT source_url AS wayback_url, schedule AS used
    FROM {{ ref('core_ca_vancouver_sofi_payments') }}
),

review AS (
    SELECT source_url AS wayback_url,
           CONCAT('review:', table_name, ' ', CAST(MIN(fiscal_year) AS STRING), '–', CAST(MAX(fiscal_year) AS STRING)) AS used
    FROM {{ ref('core_ca_vancouver_finance_lines') }}
    GROUP BY source_url, table_name
),

used AS (
    SELECT wayback_url, ARRAY_AGG(used ORDER BY used) AS used_for
    FROM (SELECT * FROM schedules UNION ALL SELECT * FROM review)
    GROUP BY 1
),

mis AS (
    SELECT report_year AS fiscal_year,
           ARRAY_AGG(STRUCT(table_name, fiscal_year_from, fiscal_year_to, evidence) ORDER BY table_name) AS misprints
    FROM {{ ref('seed_ca_vancouver_sofi_review_misprints') }}
    GROUP BY 1
)

SELECT
    d.fiscal_year,
    d.part,
    d.original_url,
    d.wayback_url,
    d.captured_on,
    d.sha256,
    COALESCE(u.used_for, [])  AS used_for,
    IF(d.part = 'statement', COALESCE(m.misprints, []), []) AS misprints
FROM docs d
LEFT JOIN used u USING (wayback_url)
LEFT JOIN mis m USING (fiscal_year)
