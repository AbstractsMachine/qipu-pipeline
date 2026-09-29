-- =============================================================================
-- Mart: what a US town owes — its debt, town × fiscal year × issue, the
-- "Dette" block of the French commune page, where the state files each
-- issue: Indiana (Gateway AFR Debt) and California (SCO Cities Raw Data);
-- all the town's funds, utilities included. Totals for every state with a
-- source: mart_us_lf_town_debt_total.
-- =============================================================================

SELECT
    'IN'                                                    AS state,
    CONCAT(county_code, '-', unit_code)                     AS government_key,
    fiscal_year,
    debt_class,
    -- the state form's capitals, in normal case (as the category lines)
    IF(fund_name = UPPER(fund_name), INITCAP(fund_name), fund_name) AS fund_name,
    description,
    SUM(outstanding_usd)                                    AS outstanding_usd,
    SUM(due_within_year_usd)                                AS due_within_year_usd
FROM {{ ref('stg_us_in_afr_debt') }}
WHERE IFNULL(outstanding_usd, 0) > 0
GROUP BY 1, 2, 3, 4, 5, 6

UNION ALL
SELECT
    'CA',
    t.government_key,
    c.fiscal_year,
    c.debt_type,
    c.fund_type,
    c.purpose,
    SUM(c.outstanding_usd),
    SUM(c.due_within_year_usd)
FROM {{ ref('stg_us_ca_city_debt') }} c
JOIN (SELECT government_key, {{ us_lf_name_key('source_name') }} AS name_exact
      FROM {{ ref('mart_us_lf_towns') }} WHERE state = 'CA') t
  ON t.name_exact = {{ us_lf_name_key('c.city_name') }}
WHERE IFNULL(c.outstanding_usd, 0) > 0
GROUP BY 1, 2, 3, 4, 5, 6
