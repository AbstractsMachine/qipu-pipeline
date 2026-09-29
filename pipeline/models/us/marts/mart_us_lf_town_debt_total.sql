-- =============================================================================
-- Mart: what a US town owes, town × fiscal year — outstanding long-term debt
-- at year end, principal due within a year where the state gives it, and
-- general-fund debt service (Massachusetts). One figure per state source:
--   IN  sum of the issues of the Gateway AFR Debt file (every fund)
--   CA  sum of the issues of the SCO Cities Raw Data (bonds, COPs, loans)
--   MA  DLS total outstanding debt (Schedule A Part 10)
--   IA  Iowa Treasurer, total outstanding obligations at June 30
-- Florida publishes no bulk debt file: none.
-- =============================================================================

WITH towns AS (
    SELECT state, government_key,
           {{ us_lf_name_key('source_name') }}                  AS name_exact,
           {{ us_lf_name_key('source_name', strip_type=true) }} AS name_key
    FROM {{ ref('mart_us_lf_towns') }}
    WHERE state IN ('IA', 'CA')
),

ca AS (
    SELECT t.government_key, c.fiscal_year, SUM(c.outstanding_usd) AS outstanding_usd,
           SUM(c.due_within_year_usd) AS due_within_year_usd,
           LOGICAL_OR(t.name_exact = {{ us_lf_name_key('c.city_name') }}) AS exact
    FROM {{ ref('stg_us_ca_city_debt') }} c
    JOIN towns t ON t.state = 'CA'
     AND (t.name_exact = {{ us_lf_name_key('c.city_name') }}
          OR t.name_key = {{ us_lf_name_key('c.city_name', strip_type=true) }})
    GROUP BY 1, 2, c.city_name
    -- the exact name wins over the name without its type word (see Iowa below)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY t.government_key, c.fiscal_year ORDER BY IF(exact, 0, 1)) = 1
),

ia AS (
    SELECT t.government_key, d.fiscal_year, d.outstanding_usd
    FROM {{ ref('stg_us_ia_treasurer_debt') }} d
    JOIN towns t ON t.state = 'IA'
     AND (t.name_exact = {{ us_lf_name_key('d.city_name') }}
          OR t.name_key = {{ us_lf_name_key('d.city_name', strip_type=true) }})
    -- Rockwell and Rockwell City are two Iowa towns: the exact name wins
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY t.government_key, d.fiscal_year
        ORDER BY IF(t.name_exact = {{ us_lf_name_key('d.city_name') }}, 0, 1)) = 1
)

SELECT state, government_key, fiscal_year, 'in_afr_debt' AS basis,
       SUM(outstanding_usd) AS outstanding_usd, SUM(due_within_year_usd) AS due_within_year_usd,
       CAST(NULL AS NUMERIC) AS gf_debt_service_usd
FROM {{ ref('mart_us_lf_town_debt') }}
WHERE state = 'IN'
GROUP BY 1, 2, 3

UNION ALL
SELECT 'CA', government_key, fiscal_year, 'ca_sco_debt', outstanding_usd, due_within_year_usd, CAST(NULL AS NUMERIC)
FROM ca

UNION ALL
SELECT 'MA', dor_code, fiscal_year, 'ma_dls_debt', outstanding_usd, CAST(NULL AS NUMERIC), gf_debt_service_usd
FROM {{ ref('stg_us_ma_long_term_debt') }}

UNION ALL
SELECT 'IA', government_key, fiscal_year, 'ia_treasurer', outstanding_usd, CAST(NULL AS NUMERIC), CAST(NULL AS NUMERIC)
FROM ia
