-- =============================================================================
-- Intermediate: department display-name dimension — one row per code
--
-- Source: core_us_sf_budget ∪ core_us_sf_actuals (both carry the editorial
--         stg_us_sf_dept_names row-level). Grain: department_code, only codes
--         with a display name.
-- =============================================================================

SELECT
    department_code,
    ANY_VALUE(department_display_name)             AS display_name,
    ANY_VALUE(department_display_name_provenance)  AS provenance
FROM (
    SELECT department_code, department_display_name, department_display_name_provenance
    FROM {{ ref('core_us_sf_budget') }}
    UNION ALL
    SELECT department_code, department_display_name, department_display_name_provenance
    FROM {{ ref('core_us_sf_actuals') }}
)
WHERE department_display_name IS NOT NULL
GROUP BY department_code
