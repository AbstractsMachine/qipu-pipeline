-- =============================================================================
-- Core: the City money tied to each curated landmark
-- (seed_ca_vancouver_landmarks), one row per landmark × record × year.
--
-- Three kinds, each read from its own published document, never mixed:
--   grant     a line of the SOFI grant schedule paid to the landmark's
--             operator: payee_key is one of the seed's operator_payee_keys
--             (reviewed by hand; a key belongs to one landmark). Supplier
--             lines to the same organisation are NOT counted — they pay for
--             goods and services, not for running the place. record_id =
--             the printed line (line_id), with its PDF and page.
--   capital   a capital program whose printed name names the landmark: the
--             seed's capital_pattern matches one of the names the program was
--             printed under, whole words (ca_words), and capital_exclude does
--             not. Amount: the new multi-year budget approved in that budget
--             year (mart_ca_vancouver_capital_program_years) — money approved,
--             net (a closed program counts below zero).
--   contract  an awarded competition whose description names the landmark,
--             the same way (contract_pattern / contract_exclude), minus the
--             kinds that are not money spent on the place: concession and
--             rental operators (they pay the City), goods for resale
--             (beverages, beer, liquor) and the parking operator. Amount: the
--             awarded total (mart_ca_vancouver_bids), in its award year.
-- A capital program or a competition that names two landmarks counts once,
-- for the one its name names FIRST (ties by slug) — "Orpheum and Queen
-- Elizabeth Theatre Chiller Replacements" is the Orpheum's.
-- How the kinds add up (grants + the larger of capital and contracts, never
-- both) is the mart's: mart_ca_vancouver_landmarks.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

WITH lm AS (
    SELECT * FROM {{ ref('seed_ca_vancouver_landmarks') }}
),

-- ── grants: the operator's grant lines ──
op AS (
    SELECT slug, TRIM(k) AS payee_key
    FROM lm, UNNEST(SPLIT(operator_payee_keys, ';')) AS k
    WHERE operator_payee_keys IS NOT NULL AND TRIM(k) != ''
),

grants AS (
    SELECT op.slug,
           'grant'                  AS kind,
           s.line_id                AS record_id,
           s.payee_key              AS record_key,
           s.payee_name             AS record_label,
           s.category               AS record_detail,
           s.fiscal_year            AS year,
           s.amount_cad,
           'Statement of Financial Information, schedule of grants' AS source_name,
           s.source_url,
           s.page                   AS source_page,
           CAST(NULL AS INT64)      AS match_pos
    FROM op
    JOIN {{ ref('core_ca_vancouver_sofi_payments') }} s
      ON s.payee_key = op.payee_key AND s.schedule = 'grants'
),

-- ── capital: programs whose printed name names the landmark ──
prog_names AS (
    SELECT DISTINCT program_key, program_name
    FROM {{ ref('mart_ca_vancouver_capital_program_years') }}
    WHERE program_name IS NOT NULL
),

prog_hit AS (
    SELECT p.program_key, lm.slug,
           MIN(REGEXP_INSTR({{ ca_words('p.program_name') }}, {{ ca_word_rule_at('lm.capital_pattern') }})) AS pos
    FROM prog_names p
    CROSS JOIN lm
    WHERE lm.capital_pattern IS NOT NULL
      AND REGEXP_CONTAINS({{ ca_words('p.program_name') }}, {{ ca_word_rule('lm.capital_pattern') }})
      AND NOT (lm.capital_exclude IS NOT NULL
               AND REGEXP_CONTAINS({{ ca_words('p.program_name') }}, {{ ca_word_rule('lm.capital_exclude') }}))
    GROUP BY 1, 2
),

prog_pick AS (
    SELECT program_key, slug, pos
    FROM prog_hit
    QUALIFY ROW_NUMBER() OVER (PARTITION BY program_key ORDER BY pos, slug) = 1
),

cat AS (
    SELECT source_id, dataset_title, dataset_page_url
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
),

capital AS (
    SELECT pp.slug,
           'capital'                AS kind,
           CONCAT(py.program_key, ':', CAST(py.budget_year AS STRING)) AS record_id,
           py.program_key           AS record_key,
           py.program_name          AS record_label,
           py.service_category_1    AS record_detail,
           py.budget_year           AS year,
           COALESCE(py.new_multi_year_cad, 0) AS amount_cad,
           ct.dataset_title         AS source_name,
           ct.dataset_page_url      AS source_url,
           CAST(NULL AS INT64)      AS source_page,
           pp.pos                   AS match_pos
    FROM prog_pick pp
    JOIN {{ ref('mart_ca_vancouver_capital_program_years') }} py USING (program_key)
    LEFT JOIN cat ct ON ct.source_id = CONCAT('capital_budget_', CAST(py.budget_year AS STRING))
),

-- ── contracts: awarded competitions whose description names the landmark ──
bids AS (
    SELECT *
    FROM {{ ref('mart_ca_vancouver_bids') }}
    WHERE n_awarded > 0
      AND NOT REGEXP_CONTAINS({{ ca_words('bid_description') }},
                              r' (concessions?|alcoholic|beverages?|beer|coolers|cider|liquor|parking facility|rental service) ')
),

bid_hit AS (
    SELECT b.bid_number, lm.slug,
           REGEXP_INSTR({{ ca_words('b.bid_description') }}, {{ ca_word_rule_at('lm.contract_pattern') }}) AS pos
    FROM bids b
    CROSS JOIN lm
    WHERE lm.contract_pattern IS NOT NULL
      AND REGEXP_CONTAINS({{ ca_words('b.bid_description') }}, {{ ca_word_rule('lm.contract_pattern') }})
      AND NOT (lm.contract_exclude IS NOT NULL
               AND REGEXP_CONTAINS({{ ca_words('b.bid_description') }}, {{ ca_word_rule('lm.contract_exclude') }}))
),

bid_pick AS (
    SELECT bid_number, slug, pos
    FROM bid_hit
    QUALIFY ROW_NUMBER() OVER (PARTITION BY bid_number ORDER BY pos, slug) = 1
),

contracts AS (
    SELECT bp.slug,
           'contract'               AS kind,
           b.bid_number             AS record_id,
           b.bid_number             AS record_key,
           b.bid_description        AS record_label,
           b.bid_type_group         AS record_detail,
           b.award_year             AS year,
           COALESCE(b.awarded_total_cad, 0) AS amount_cad,
           b.source_name,
           b.source_url,
           CAST(NULL AS INT64)      AS source_page,
           bp.pos                   AS match_pos
    FROM bid_pick bp
    JOIN {{ ref('mart_ca_vancouver_bids') }} b USING (bid_number)
)

SELECT * FROM grants
UNION ALL SELECT * FROM capital
UNION ALL SELECT * FROM contracts
