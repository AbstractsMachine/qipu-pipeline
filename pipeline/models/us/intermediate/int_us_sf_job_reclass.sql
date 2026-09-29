-- =============================================================================
-- Intermediate: job-code reclassification dimension — one row per reclassified code
--
-- Source: core_us_sf_comp (carries stg_us_sf_job_reclass row-level: the manual
--         family for job codes whose portal family is '0000'/'__UNASSIGNED__').
-- Grain: job_code, only codes with a reclassification.
-- =============================================================================

SELECT
    job_code,
    ANY_VALUE(reclass_family_code)  AS reclass_family_code,
    ANY_VALUE(reclass_family)       AS reclass_family
FROM {{ ref('core_us_sf_comp') }}
WHERE reclass_family_code IS NOT NULL
GROUP BY job_code
