-- =============================================================================
-- Intermediate: payee dimension — one row per bucketed vendor string
--
-- Source: core_us_sf_vouchers (which carries the manual payee bucket seed
--         row-level). Grain: vendor. Only vendors that appear in the vouchers
--         AND have a bucket; marts LEFT JOIN it after aggregating by vendor,
--         so unbucketed vendors simply get NULLs (same as before).
-- =============================================================================

SELECT
    vendor,
    ANY_VALUE(payee_bucket)                AS bucket,
    ANY_VALUE(payee_bucket_note)           AS classification_note,
    ANY_VALUE(payee_bucket_method)         AS classification_method,
    ANY_VALUE(payee_bucket_classified_at)  AS classified_at,
    ANY_VALUE(is_aggregation_line)         AS is_aggregation_line
FROM {{ ref('core_us_sf_vouchers') }}
WHERE is_payee_bucketed
GROUP BY vendor
