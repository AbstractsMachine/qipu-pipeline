-- =============================================================================
-- Intermediate: job-family display dimension — one row per effective family code
--
-- Source: core_us_sf_comp (carries stg_us_sf_job_family_display row-level,
--         keyed on the effective family_code after reclassification).
-- Grain: job_family_code = core.family_code, only families with a label.
-- =============================================================================

SELECT
    family_code                          AS job_family_code,
    ANY_VALUE(family_canonical_label)    AS canonical_label,
    ANY_VALUE(family_display)            AS display_family
FROM {{ ref('core_us_sf_comp') }}
WHERE family_canonical_label IS NOT NULL OR family_display IS NOT NULL
GROUP BY family_code
