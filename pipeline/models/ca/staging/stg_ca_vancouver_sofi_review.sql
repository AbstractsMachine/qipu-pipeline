-- =============================================================================
-- Staging: the SOFI five-year statistical review, one row per report × table
-- × line × fiscal year, as printed.
--
-- Source: raw.ca_vancouver_sofi_review (parse_sofi_review.py). Reports 2019→
-- 2025; each restates the four years before it. `label_key` / `section_key`
-- are letters-only keys (some pages are letter-spaced in the text layer).
-- Unlabelled rows are totals: label_key 'total' (or 'grandtotal').
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

SELECT
    report_year,
    table_name,
    section,
    section_key,
    label,
    COALESCE(label_key, IF(is_total, 'total', NULL))  AS label_key,
    fiscal_year,
    CAST(value AS NUMERIC)                            AS value,
    is_total,
    page,
    line_no,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_sofi_review') }}
