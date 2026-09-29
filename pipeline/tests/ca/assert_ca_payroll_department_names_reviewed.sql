-- The reviewed department labels (seed_ca_vancouver_payroll_department_names)
-- stay sound: every row carries a display name and a reason, a City label is
-- written out once, and every label is still printed in the remuneration
-- schedule (a stale row fails).
WITH n AS (SELECT * FROM {{ ref('seed_ca_vancouver_payroll_department_names') }}),
printed AS (SELECT DISTINCT department FROM {{ ref('core_ca_vancouver_remuneration') }})
SELECT department, 'no display name or reason' AS problem FROM n
WHERE display_name IS NULL OR TRIM(display_name) = '' OR reason IS NULL OR TRIM(reason) = ''
UNION ALL
SELECT department, 'written out twice' FROM n GROUP BY department HAVING COUNT(*) > 1
UNION ALL
SELECT n.department, 'label not in the schedule' FROM n LEFT JOIN printed p ON p.department = n.department WHERE p.department IS NULL
