-- =============================================================================
-- Mart: the 2023–2026 Capital Plan by category × sub-category: original and
-- revised plan, city-led vs developer-led in-kind, what the four budgets have
-- allocated and the remainder. Provenance from the catalog.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH cat AS (
    SELECT dataset_title, dataset_page_url, license_title, rows_updated_at
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
    WHERE source_id = 'capital_plan_2023_2026'
)

SELECT
    p.service_category_1,
    p.service_category_2,
    COUNT(*)                    AS n_programs,
    SUM(p.original_plan_cad)    AS original_plan_cad,
    SUM(p.revised_plan_cad)     AS revised_plan_cad,
    SUM(p.city_led_cad)         AS city_led_cad,
    SUM(p.developer_in_kind_cad) AS developer_in_kind_cad,
    SUM(p.allocated_2023_cad)   AS allocated_2023_cad,
    SUM(p.allocated_2024_cad)   AS allocated_2024_cad,
    SUM(p.allocated_2025_cad)   AS allocated_2025_cad,
    SUM(p.allocated_2026_cad)   AS allocated_2026_cad,
    SUM(p.remainder_cad)        AS remainder_cad,
    ANY_VALUE(c.dataset_title)  AS source_name,
    ANY_VALUE(c.dataset_page_url) AS source_url,
    ANY_VALUE(c.license_title)  AS source_license,
    ANY_VALUE(c.rows_updated_at) AS source_rows_updated_at
FROM {{ ref('core_ca_vancouver_capital_plan_lines') }} p
CROSS JOIN cat c
GROUP BY 1, 2
