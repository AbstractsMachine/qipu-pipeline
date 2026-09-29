-- The reviewed capital program merges (seed_ca_vancouver_capital_program_merges)
-- stay sound:
--   · every row carries a reason;
--   · a printed key is merged once and is never itself a merge target (no chains);
--   · both keys are still printed in the capital budgets (a stale row fails);
--   · no budget year prints both keys — two lines in one year are two programs,
--     never one program spelled twice.
WITH m AS (SELECT * FROM {{ ref('seed_ca_vancouver_capital_program_merges') }}),
printed AS (
    SELECT DISTINCT budget_year, program_key_printed AS k
    FROM {{ ref('core_ca_vancouver_capital_budget_lines') }}
    WHERE program_key_printed != ''
)
SELECT printed_key, 'no reason' AS problem FROM m WHERE reason IS NULL OR TRIM(reason) = ''
UNION ALL
SELECT printed_key, 'merged twice' FROM m GROUP BY printed_key HAVING COUNT(*) > 1
UNION ALL
SELECT m.printed_key, 'chain: printed key is also a target' FROM m JOIN m t ON t.program_key = m.printed_key
UNION ALL
SELECT m.printed_key, 'printed key not in the budgets' FROM m WHERE m.printed_key NOT IN (SELECT k FROM printed)
UNION ALL
SELECT m.printed_key, 'target key not in the budgets' FROM m WHERE m.program_key NOT IN (SELECT k FROM printed)
UNION ALL
SELECT g.grp, CONCAT('two keys of one program printed in ', CAST(p.budget_year AS STRING))
FROM (SELECT printed_key AS k, program_key AS grp FROM m UNION DISTINCT SELECT program_key, program_key FROM m) g
JOIN printed p ON p.k = g.k
GROUP BY g.grp, p.budget_year
HAVING COUNT(DISTINCT g.k) > 1
