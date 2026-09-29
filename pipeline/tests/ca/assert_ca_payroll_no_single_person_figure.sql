-- Privacy gate: no payroll figure the site exports is one person's pay — a
-- median or a band total over fewer than 10 people is NULL, and no
-- department-year of fewer than 3 people is a row (its total would be one
-- or two people's pay).
SELECT 'band' AS kind, fiscal_year, CAST(band_floor_cad AS STRING) AS grp
FROM {{ ref('mart_ca_vancouver_payroll_bands') }}
WHERE n_people < 10 AND remuneration_total_cad IS NOT NULL
UNION ALL
SELECT 'department', fiscal_year, department
FROM {{ ref('mart_ca_vancouver_payroll_departments') }}
WHERE n_people < 10 AND median_cad IS NOT NULL
UNION ALL
SELECT 'department_total', fiscal_year, department
FROM {{ ref('mart_ca_vancouver_payroll_departments') }}
WHERE n_people < 3
UNION ALL
SELECT 'title', d.fiscal_year, t.title
FROM {{ ref('mart_ca_vancouver_payroll_departments') }} d, UNNEST(d.titles) t
WHERE (t.n_people < 10 AND t.median_cad IS NOT NULL) OR t.n_people < 3
