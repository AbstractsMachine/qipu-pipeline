-- =============================================================================
-- Staging: Indiana line-item budget estimates (Form 1), cities and towns, 2019+
--
-- Source: raw.us_in_budget_line_items (Indiana Gateway, Budget Data)
-- Grain:  one row per budget line (unit × fund × department × category × item);
--         no natural key — the same item text can repeat inside a department.
--
-- published_usd = amount advertised; approved_usd = amount adopted. The
-- department list is a state list shared with the AFR disbursements.
-- =============================================================================

SELECT
    {{ us_lf_int('year') }}                             AS budget_year,
    {{ us_lf_string('cnty_cd') }}                       AS county_code,
    {{ us_lf_string('cnty_description') }}              AS county_name,
    {{ us_lf_string('unit_type') }}                     AS unit_type_code,
    {{ us_lf_string('unit_type_label') }}               AS unit_type,
    {{ us_lf_string('unit_code') }}                     AS unit_code,
    {{ us_lf_string('unit_name') }}                     AS unit_name,
    {{ us_lf_string('sboa_id') }}                       AS sboa_id,
    {{ us_lf_string('fund_cd') }}                       AS fund_code,
    {{ us_lf_string('fund_description') }}              AS fund_name,
    {{ us_lf_string('department_cd') }}                 AS department_code,
    {{ us_lf_string('department_description') }}        AS department_name,
    {{ us_lf_string('expenditure_cat_id') }}            AS expenditure_category_code,
    {{ us_lf_string('expenditure_cat_description') }}   AS expenditure_category,
    {{ us_lf_string('expenditure_subcat_id') }}         AS expenditure_subcategory_code,
    {{ us_lf_string('expenditure_subcat_description') }} AS expenditure_subcategory,
    {{ us_lf_string('item_ref_code') }}                 AS item_ref_code,
    {{ us_lf_string('item_description') }}              AS item_description,
    {{ us_lf_amount('item_amt') }}                      AS published_usd,
    {{ us_lf_amount('item_approved_amt') }}             AS approved_usd,
    _source                                             AS source,
    _source_url                                         AS source_url,
    _synced_at
FROM {{ source('us_local_finance_raw', 'us_in_budget_line_items') }}
