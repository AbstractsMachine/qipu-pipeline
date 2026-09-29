-- =============================================================================
-- Mart: grant recipients by category and year — the grant-category fiche's
-- lists. One row per category × fiscal year × named recipient (organisations
-- and public bodies; a withheld name is summed into one row per category-year
-- with payee_key NULL, never named).
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH g AS (
    SELECT fiscal_year, category, payee_kind,
           IF(payee_kind = 'withheld', NULL, payee_key)  AS payee_key,
           IF(payee_kind = 'withheld', NULL, payee_name) AS payee_name,
           amount_cad
    FROM {{ ref('core_ca_vancouver_sofi_payments') }}
    WHERE schedule = 'grants'
),

named AS (
    SELECT fiscal_year, category, payee_key,
           ARRAY_AGG(payee_name ORDER BY amount_cad DESC LIMIT 1)[OFFSET(0)] AS payee_name,
           SUM(amount_cad) AS amount_cad, COUNT(*) AS n_lines
    FROM g
    GROUP BY 1, 2, 3
)

SELECT
    n.*,
    -- only keys the payees mart publishes get a fiche link
    p.payee_key IS NOT NULL AS has_fiche
FROM named n
LEFT JOIN {{ ref('mart_ca_vancouver_payees') }} p USING (payee_key)
