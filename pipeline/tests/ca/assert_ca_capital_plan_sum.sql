-- Σ revised 2023–2026 Capital Plan survives raw → mart to the dollar.
WITH r AS (SELECT SUM(`2023_2026_revised_capital_plan`) AS s FROM {{ source('ca_vancouver_raw', 'ca_vancouver_capital_plan_2023_2026') }}),
     m AS (SELECT SUM(revised_plan_cad) AS s FROM {{ ref('mart_ca_vancouver_capital_plan') }})
SELECT r.s, m.s FROM r, m WHERE ABS(CAST(r.s AS NUMERIC) - m.s) > 1
