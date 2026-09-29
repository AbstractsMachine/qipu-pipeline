-- =============================================================================
-- Core: one row per schedule × category × fiscal year — the total the City
-- printed, the sum of the lines we parsed, and whether they agree.
--
-- control_cad: the printed over-threshold total (the revised one when the
--              year has amendment pages); NULL when the schedule prints none.
-- status: 'matches'     |parsed − printed| ≤ $50 (the schedules print whole
--                       dollars; a few lines' rounding is all a match allows)
--         'known_gap'   listed in seed_ca_vancouver_sofi_known_gaps with what
--                       was measured
--         'no_control'  no printed total for that category
--         'unexplained' anything else — assert_ca_sofi_controls_explained
--                       fails the build on it
-- under_threshold_cad: the one-line total of supplier payments under $25,000.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

WITH parsed AS (
    SELECT fiscal_year, schedule, category, SUM(amount_cad) AS parsed_cad, COUNT(*) AS n_lines,
           ANY_VALUE(source_url) AS source_url
    FROM {{ ref('core_ca_vancouver_sofi_payments') }}
    GROUP BY 1, 2, 3
),

printed AS (
    SELECT fiscal_year, schedule, category,
           COALESCE(MAX(IF(control_kind = 'revised', control_cad, NULL)),
                    MAX(IF(control_kind = 'over_threshold', control_cad, NULL))) AS control_cad,
           MAX(IF(control_kind = 'under_threshold', control_cad, NULL))           AS under_threshold_cad,
           ANY_VALUE(page)                                                       AS control_page
    FROM {{ ref('stg_ca_vancouver_sofi_controls') }}
    GROUP BY 1, 2, 3
),

gaps AS (
    SELECT fiscal_year, schedule, NULLIF(category, '') AS category, reason
    FROM {{ ref('seed_ca_vancouver_sofi_known_gaps') }}
)

SELECT
    p.fiscal_year,
    p.schedule,
    p.category,
    p.n_lines,
    p.parsed_cad,
    c.control_cad,
    p.parsed_cad - c.control_cad                  AS delta_cad,
    c.under_threshold_cad,
    c.control_page,
    CASE
        WHEN c.control_cad IS NOT NULL AND ABS(p.parsed_cad - c.control_cad) <= 50 THEN 'matches'
        WHEN g.reason IS NOT NULL                                               THEN 'known_gap'
        WHEN c.control_cad IS NULL                                              THEN 'no_control'
        ELSE 'unexplained'
    END                                           AS status,
    g.reason                                      AS gap_reason,
    p.source_url
FROM parsed p
LEFT JOIN printed c
  ON c.fiscal_year = p.fiscal_year AND c.schedule = p.schedule
 AND COALESCE(c.category, '') = COALESCE(p.category, '')
LEFT JOIN gaps g
  ON g.fiscal_year = p.fiscal_year AND g.schedule = p.schedule
 AND COALESCE(g.category, '') = COALESCE(p.category, '')
