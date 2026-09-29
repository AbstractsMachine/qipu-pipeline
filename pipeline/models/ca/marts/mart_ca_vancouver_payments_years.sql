-- =============================================================================
-- Mart: SOFI payment schedules by year — one row per fiscal year × schedule
-- (suppliers | grants) × category (grants only), 2011→.
--
-- total_cad        the lines as parsed (what the explorer and fiches add up)
-- printed_total_cad the total the City printed; status / gap_reason say whether
--                  the two agree (core_ca_vancouver_sofi_controls)
-- withheld_cad     lines whose payee name could be a person's (no organisation
--                  marker): counted and summed, never named
-- public_bodies_cad other governments, agencies, Crown corporations and
--                  statutory remittances (core payee_kind rule)
-- under_threshold_cad suppliers only: payments under $25,000, printed as one line
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH p AS (
    SELECT
        fiscal_year, schedule, category,
        COUNT(*)                                             AS n_lines,
        COUNT(DISTINCT IF(payee_kind != 'withheld', payee_key, NULL)) AS n_payees_named,
        COUNTIF(payee_kind = 'withheld')                     AS n_withheld_lines,
        SUM(amount_cad)                                      AS total_cad,
        SUM(IF(payee_kind = 'withheld', amount_cad, 0))      AS withheld_cad,
        SUM(IF(payee_kind = 'public_body', amount_cad, 0))   AS public_bodies_cad,
        SUM(IF(payee_kind = 'organisation', amount_cad, 0))  AS organisations_cad,
        COUNTIF(is_amendment)                                AS n_amendment_lines,
        ANY_VALUE(source_url)                                AS source_url,
        ANY_VALUE(source_original_url)                       AS source_original_url
    FROM {{ ref('core_ca_vancouver_sofi_payments') }}
    GROUP BY 1, 2, 3
)

SELECT
    p.*,
    c.control_cad          AS printed_total_cad,
    c.delta_cad,
    c.under_threshold_cad,
    c.status,
    c.gap_reason
FROM p
LEFT JOIN {{ ref('core_ca_vancouver_sofi_controls') }} c
  ON c.fiscal_year = p.fiscal_year AND c.schedule = p.schedule
 AND COALESCE(c.category, '') = COALESCE(p.category, '')
