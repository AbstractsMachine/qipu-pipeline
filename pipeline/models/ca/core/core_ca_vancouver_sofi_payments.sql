-- =============================================================================
-- Core: SOFI payments OBT — one row per printed line of the supplier (over
-- $25,000) and grant schedules, 2011→, with the document it was read from.
--
-- Grain: fiscal_year × schedule × category × printed line. The same payee can
-- appear twice in a year (an amendment page re-lists it; the grant schedule
-- lists an organisation under two categories) — lines are what the City
-- printed, so they are kept, and marts sum them.
-- source_url: the Internet Archive capture of the PDF; 2017 and 2018 printed
-- the schedules in a separate supply-management file.
-- payee_kind, a name rule published on the page, first match wins:
--   'public_body'  other governments, their agencies and Crown corporations,
--                  and the statutory remittances (pension plan, workers'
--                  compensation, Receiver General) the schedule lists beside
--                  suppliers — a public body's name is never withheld;
--   'withheld'     the parser's is_individual: the name carries no
--                  organisation marker, so it COULD be a person's. This is not
--                  a finding that it is one (many are trade names);
--   'organisation' everything else.
-- payee_key: the organisation. ca_org_key joins spellings that are the same
--   words; seed_ca_vancouver_payee_merges (reviewed, one reason per row) maps
--   the keys it cannot join — "Scott Special Project" 2011–2023 and "Scott
--   Special Projects Ltd." 2024– — onto one. payee_key_printed keeps the key of
--   the spelling as printed, so a merge can be traced and old links redirected.
-- PRIVACY: payee_name is kept for grain integrity ONLY; marts sum 'withheld'
-- lines and never emit their names.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

WITH docs AS (
    SELECT d.fiscal_year, d.original_url, d.wayback_url, d.captured_on
    FROM {{ ref('stg_ca_vancouver_sofi_documents') }} d
    QUALIFY ROW_NUMBER() OVER (PARTITION BY d.fiscal_year ORDER BY d.part = 'supply-management' DESC) = 1
)

SELECT
    {{ dbt_utils.generate_surrogate_key(['p.fiscal_year', 'p.schedule', 'p.category', 'p.page', 'p.payee_name', 'p.amount_cad', 'p.is_amendment']) }}
                                  AS line_id,
    p.fiscal_year,
    p.schedule,
    p.category,
    p.payee_name,
    COALESCE(m.payee_key, p.payee_key) AS payee_key,
    p.payee_key                   AS payee_key_printed,
    p.amount_cad,
    p.is_individual,
    CASE
        WHEN REGEXP_CONTAINS(LOWER(p.payee_name), r"crime stoppers")                      THEN IF(p.is_individual, 'withheld', 'organisation')
        WHEN REGEXP_CONTAINS(LOWER(p.payee_name), r"\b(receiver general|rec\. general|minister of fin|ministry of|province of b|government of|pension plan|workers.? compensation|worksafe|greater vancouver (water|sewerage|regional)|greater vanc?\.? ?(water|sewerage)|metro vancouver|translink|south coast british columbia transportation|bc assessment|municipal finance authority|school district|board of education|city of |district of |regional district|e-?comm|emergency communications for b|bc hydro|insurance corporation of british columbia|icbc|vancouver coastal health|provincial health services|bc housing|british columbia housing)")
                                                                                          THEN 'public_body'
        WHEN p.is_individual                                                              THEN 'withheld'
        ELSE 'organisation'
    END                           AS payee_kind,
    p.is_amendment,
    p.page,
    d.original_url                AS source_original_url,
    d.wayback_url                 AS source_url,
    d.captured_on                 AS source_captured_on,
    p._synced_at
FROM {{ ref('stg_ca_vancouver_sofi_payments') }} p
LEFT JOIN docs d USING (fiscal_year)
LEFT JOIN {{ ref('seed_ca_vancouver_payee_merges') }} m ON m.printed_key = p.payee_key
