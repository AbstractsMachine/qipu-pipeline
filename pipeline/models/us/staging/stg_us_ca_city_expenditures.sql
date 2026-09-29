-- =============================================================================
-- Staging: California cities' expenditures, Cities Annual Report filed with
-- the State Controller (actuals)
--
-- Source: raw.us_ca_sco_city_expenditures (SCO By the Numbers, ju3w-4gxp)
-- Grain:  one row per row_number = city × fiscal year × form line × fund
--         category. fiscal_year 2024 = the year July 2023 - June 2024.
-- category holds either a group of governmental functions ("General
-- Government and Public Safety") or one fund (each enterprise fund, the
-- internal service fund, conduit financing); subcategory_1 the function or
-- the expense class, subcategory_2 the line. No subtotal rows.
-- =============================================================================

SELECT
    {{ us_lf_string('entity_name') }}                   AS city_name,
    {{ us_lf_string('county') }}                        AS county,
    {{ us_lf_int('fiscal_year') }}                      AS fiscal_year,
    {{ us_lf_string('form_table') }}                    AS form_table,
    {{ us_lf_string('category') }}                      AS category,
    {{ us_lf_string('subcategory_1') }}                 AS subcategory_1,
    {{ us_lf_string('subcategory_2') }}                 AS subcategory_2,
    {{ us_lf_string('line_description') }}              AS line_description,
    {{ us_lf_amount('value') }}                         AS amount_usd,
    {{ us_lf_int('estimated_population') }}             AS estimated_population,
    {{ us_lf_string('row_number') }}                    AS row_number,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_ca_sco_city_expenditures') }}
