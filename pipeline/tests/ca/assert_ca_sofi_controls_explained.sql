-- Every SOFI supplier/grant schedule either sums to the total the City
-- printed (±$50) or is listed, with what was measured, in
-- seed_ca_vancouver_sofi_known_gaps. A new gap fails the build.
SELECT fiscal_year, schedule, category, parsed_cad, control_cad, delta_cad
FROM {{ ref('core_ca_vancouver_sofi_controls') }}
WHERE status = 'unexplained'
