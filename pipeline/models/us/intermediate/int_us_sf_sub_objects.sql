-- =============================================================================
-- Intermediate: sub-object spend-class dimension — one row per classified code
--
-- Source: core_us_sf_vouchers (carries stg_us_sf_subobject_class row-level).
-- Grain: sub_object_code, only codes with a spend class.
-- =============================================================================

SELECT
    sub_object_code,
    ANY_VALUE(sub_object_spend_class)               AS spend_class,
    ANY_VALUE(sub_object_spend_class_basis)         AS basis,
    ANY_VALUE(sub_object_spend_class_needs_review)  AS needs_review
FROM {{ ref('core_us_sf_vouchers') }}
WHERE sub_object_spend_class IS NOT NULL
GROUP BY sub_object_code
