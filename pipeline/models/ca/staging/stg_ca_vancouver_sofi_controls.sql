-- =============================================================================
-- Staging: the totals printed on the SOFI supplier and grant schedules.
--
-- Source: raw.ca_vancouver_sofi_controls (parse_sofi.py). `schedule` arrives
-- as 'suppliers' or 'grants:<category>'. The City words the supplier totals
-- differently most years ("Total - Suppliers Over $25,000", "Vendors >
-- $25,000", "Revised Total" after an amendment); `control_kind` names them:
--   over_threshold  the schedule's own total (what the parsed lines must sum to)
--   revised         the over-threshold total after the amendment pages
--   under_threshold payments under $25,000, printed as one number
--   all_payments    over + under
--   other           "Previously reported", "Total amendment"
-- =============================================================================

{{ config(materialized='view', schema='ca_staging', tags=['ca', 'staging']) }}

SELECT
    fiscal_year,
    SPLIT(schedule, ':')[OFFSET(0)]                                     AS schedule,
    IF(STRPOS(schedule, ':') > 0, SUBSTR(schedule, STRPOS(schedule, ':') + 1), NULL) AS category,
    label,
    CASE
        WHEN schedule != 'suppliers'                                   THEN 'over_threshold'
        WHEN REGEXP_CONTAINS(LOWER(label), r'revised')                 THEN 'revised'
        WHEN REGEXP_CONTAINS(LOWER(label), r'previously|amendment')    THEN 'other'
        WHEN REGEXP_CONTAINS(LOWER(label), r'over|>')                  THEN 'over_threshold'
        WHEN REGEXP_CONTAINS(LOWER(label), r'under|<')                 THEN 'under_threshold'
        WHEN REGEXP_CONTAINS(LOWER(label), r'^total$')                 THEN 'all_payments'
        ELSE 'other'
    END                                                                 AS control_kind,
    CAST(amount_cad AS NUMERIC)                                         AS control_cad,
    CAST(parsed_sum_cad AS NUMERIC)                                     AS parsed_sum_cad,
    page,
    _synced_at
FROM {{ source('ca_vancouver_raw', 'ca_vancouver_sofi_controls') }}
