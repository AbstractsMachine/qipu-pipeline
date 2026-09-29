-- The reviewed housing operator → payee links (seed_ca_vancouver_housing_operator_payees)
-- stay sound:
--   · every row carries a reason, and an operator is linked once;
--   · the operator is on the housing register (a stale row fails);
--   · the payee is a NAMED payee of mart_ca_vancouver_payees — a seed row can
--     never publish a withheld name or point at a folded key;
--   · the seed only fills misses: an operator the exact organisation key
--     already joins is not in it (two answers would disagree silently).
WITH s AS (SELECT * FROM {{ ref('seed_ca_vancouver_housing_operator_payees') }}),
reg AS (
    SELECT DISTINCT LOWER(JSON_VALUE(facts, '$.operator')) AS k, JSON_VALUE(facts, '$.operator') AS operator
    FROM {{ ref('mart_ca_vancouver_places') }}
    WHERE place_kind = 'non_market_housing' AND JSON_VALUE(facts, '$.operator') IS NOT NULL
),
exact AS (
    SELECT DISTINCT r.k
    FROM reg r
    JOIN (SELECT DISTINCT payee_key_printed FROM {{ ref('core_ca_vancouver_sofi_payments') }} WHERE payee_key != '') pr
      ON pr.payee_key_printed = {{ ca_org_key('r.operator') }}
)
SELECT s.operator, 'no reason' AS problem FROM s WHERE s.reason IS NULL OR TRIM(s.reason) = ''
UNION ALL
SELECT operator, 'linked twice' FROM s GROUP BY operator HAVING COUNT(*) > 1
UNION ALL
SELECT s.operator, 'operator not on the register' FROM s LEFT JOIN (SELECT DISTINCT k FROM reg) r ON r.k = LOWER(s.operator) WHERE r.k IS NULL
UNION ALL
SELECT s.operator, 'payee not a named payee' FROM s LEFT JOIN {{ ref('mart_ca_vancouver_payees') }} p USING (payee_key) WHERE p.payee_key IS NULL
UNION ALL
SELECT s.operator, 'exact key already joins' FROM s JOIN exact e ON e.k = LOWER(s.operator)
