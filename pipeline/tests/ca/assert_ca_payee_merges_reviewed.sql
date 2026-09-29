-- The reviewed payee merges (seed_ca_vancouver_payee_merges) stay sound:
--   · every row carries a reason;
--   · a printed key is merged once and is never itself a merge target (no chains);
--   · both keys are still printed in the schedules (a stale row fails);
--   · PRIVACY: neither side ever holds a withheld line — a merge must not carry
--     a name that could be a person's into the payees mart, nor hide one there.
WITH m AS (SELECT * FROM {{ ref('seed_ca_vancouver_payee_merges') }}),
stg AS (SELECT DISTINCT payee_key FROM {{ ref('stg_ca_vancouver_sofi_payments') }}),
core AS (SELECT payee_key_printed, LOGICAL_OR(payee_kind = 'withheld') AS any_withheld FROM {{ ref('core_ca_vancouver_sofi_payments') }} GROUP BY 1)
SELECT printed_key, 'no reason' AS problem FROM m WHERE reason IS NULL OR TRIM(reason) = ''
UNION ALL
SELECT printed_key, 'merged twice' FROM m GROUP BY printed_key HAVING COUNT(*) > 1
UNION ALL
SELECT m.printed_key, 'chain: printed key is also a target' FROM m JOIN m t ON t.payee_key = m.printed_key
UNION ALL
SELECT m.printed_key, 'printed key not in the schedules' FROM m LEFT JOIN stg s ON s.payee_key = m.printed_key WHERE s.payee_key IS NULL
UNION ALL
SELECT m.printed_key, 'target key not in the schedules' FROM m LEFT JOIN stg s ON s.payee_key = m.payee_key WHERE s.payee_key IS NULL
UNION ALL
SELECT m.printed_key, 'withheld line on a merged key' FROM m
JOIN core c ON c.payee_key_printed IN (m.printed_key, m.payee_key)
WHERE c.any_withheld
