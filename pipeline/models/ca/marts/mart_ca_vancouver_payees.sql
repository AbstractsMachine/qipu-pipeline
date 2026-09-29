-- =============================================================================
-- Mart: payees — one row per ORGANISATION the City paid over $25,000 or gave
-- a grant to, 2011→ (payee_key merges spelling variants, as vendor_key does).
--
-- Named payees only: a key any of whose lines is withheld (a name that could be
-- a person's) is left out whole — its lines are summed in
-- mart_ca_vancouver_payments_years, never listed.
-- by_year: supplier and grant dollars per fiscal year. categories: grant
-- dollars per category. Contracts: when the same key is a vendor in the
-- awarded-contracts register, what it won there — two registers, joined only
-- on the same ca_org_key (same words, legal form aside), through any of the
-- spellings the payee was printed under; contract_vendor_keys lists every
-- vendor fiche that joins (the vendor fiche links back through it).
-- merged_keys: the printed keys seed_ca_vancouver_payee_merges folded into this
-- payee (empty for most) — the website redirects their old URLs here.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH lines AS (
    SELECT *
    FROM {{ ref('core_ca_vancouver_sofi_payments') }}
    WHERE payee_key != ''
),

people AS (
    SELECT DISTINCT payee_key FROM {{ ref('core_ca_vancouver_sofi_payments') }} WHERE payee_kind = 'withheld'
),

names AS (
    -- the latest spelling, taken from the payee's own key first: a merged
    -- spelling is often the one with an account number or a cut name
    SELECT payee_key, payee_name
    FROM lines
    QUALIFY ROW_NUMBER() OVER (PARTITION BY payee_key ORDER BY payee_key_printed = payee_key DESC, fiscal_year DESC, amount_cad DESC, payee_name) = 1
),

yr AS (
    SELECT payee_key, fiscal_year,
           SUM(IF(schedule = 'suppliers', amount_cad, 0)) AS supplier_cad,
           SUM(IF(schedule = 'grants', amount_cad, 0))    AS grant_cad
    FROM lines
    GROUP BY 1, 2
),

cats AS (
    SELECT payee_key, category, SUM(amount_cad) AS grant_cad, COUNT(DISTINCT fiscal_year) AS n_years
    FROM lines
    WHERE schedule = 'grants'
    GROUP BY 1, 2
),

agg AS (
    SELECT
        payee_key,
        COUNT(DISTINCT payee_name)                    AS n_spellings,
        LOGICAL_OR(payee_kind = 'public_body')        AS is_public_body,
        SUM(IF(schedule = 'suppliers', amount_cad, 0)) AS supplier_total_cad,
        SUM(IF(schedule = 'grants', amount_cad, 0))    AS grant_total_cad,
        SUM(amount_cad)                                AS total_cad,
        MIN(fiscal_year)                               AS first_year,
        MAX(fiscal_year)                               AS last_year,
        COUNT(DISTINCT fiscal_year)                    AS n_years
    FROM lines
    GROUP BY 1
),

yr_arr AS (
    SELECT payee_key, ARRAY_AGG(STRUCT(fiscal_year, supplier_cad, grant_cad) ORDER BY fiscal_year) AS by_year
    FROM yr
    GROUP BY 1
),

cat_arr AS (
    SELECT payee_key, ARRAY_AGG(STRUCT(category, grant_cad, n_years) ORDER BY grant_cad DESC, category) AS categories
    FROM cats
    GROUP BY 1
),

printed AS (
    SELECT DISTINCT payee_key, payee_key_printed FROM lines
),

merged AS (
    SELECT payee_key, ARRAY_AGG(payee_key_printed ORDER BY payee_key_printed) AS merged_keys
    FROM printed
    WHERE payee_key_printed != payee_key
    GROUP BY 1
),

v AS (
    -- one contract vendor per payee; when two vendor fiches collapse onto it
    -- (two vendor keys, or two of the payee's printed spellings) the larger
    -- links, and both count in contracts_awarded_cad
    SELECT pr.payee_key,
           ARRAY_AGG(vd.vendor_key ORDER BY vd.awarded_total_cad DESC NULLS LAST, vd.vendor_key LIMIT 1)[OFFSET(0)] AS vendor_key,
           ARRAY_AGG(vd.vendor_key ORDER BY vd.vendor_key) AS vendor_keys,
           SUM(vd.awarded_total_cad) AS awarded_total_cad, SUM(vd.n_competitions_won) AS n_competitions_won,
           SUM(vd.n_competitions) AS n_competitions
    FROM {{ ref('mart_ca_vancouver_vendors') }} vd
    JOIN printed pr ON pr.payee_key_printed = {{ ca_org_key('vd.vendor_name') }}
    GROUP BY 1
)

SELECT
    a.payee_key,
    n.payee_name,
    a.n_spellings,
    a.is_public_body,
    a.supplier_total_cad,
    a.grant_total_cad,
    a.total_cad,
    a.first_year,
    a.last_year,
    a.n_years,
    ya.by_year,
    COALESCE(ca.categories, [])                                                 AS categories,
    v.vendor_key                                                                AS contract_vendor_key,
    COALESCE(v.vendor_keys, [])                                                 AS contract_vendor_keys,
    v.awarded_total_cad                                                         AS contracts_awarded_cad,
    v.n_competitions_won                                                        AS contracts_won,
    v.n_competitions                                                            AS contracts_entered,
    COALESCE(mg.merged_keys, [])                                                AS merged_keys
FROM agg a
LEFT JOIN people pe USING (payee_key)
JOIN names n USING (payee_key)
JOIN yr_arr ya USING (payee_key)
LEFT JOIN cat_arr ca USING (payee_key)
LEFT JOIN v USING (payee_key)
LEFT JOIN merged mg USING (payee_key)
WHERE pe.payee_key IS NULL
