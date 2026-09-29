-- =============================================================================
-- Core: SF Actuals OBT — row-level spending and revenue actuals
--
-- Source: stg_us_sf_actuals
-- Grain:  row-level (FY × side × related_govt_units × org/dept/program ×
--         character/object/sub_object × fund hierarchy) — rollups in marts.
--
-- Reconciliation-relevant flags (docs/us/API-RECON.md §A.2 + live
-- verification 2026-07-16 — see mart_us_sf_budget_vs_actual):
--   - is_related_govt_unit: OCII, Retirement System, Health Service System,
--     Superior Court etc. — these entities are NOT in the budget dataset
--     at all (verified: their department codes return zero budget rows).
--   - is_transfer_adjustment: the actuals dataset ALSO carries negative
--     "Transfer Adjustment(s)" rows (both chart-of-accounts eras) — a
--     naive SUM(amount) is therefore already partially netted.
--   - is_transfer_character: any transfer character (in/out/adjustment).
--   - is_fiscal_year_complete: SF FY N = Jul 1 (N-1) → Jun 30 N; the
--     dataset contains in-progress fiscal years (FY2027 at ~$0.3B).
-- =============================================================================

WITH actuals AS (
    SELECT *
    FROM {{ ref('stg_us_sf_actuals') }}
),

-- Editorial department display names — seed, display only (same as core_us_sf_budget).
dept_names AS (
    SELECT department_code, display_name, provenance
    FROM {{ ref('stg_us_sf_dept_names') }}
)

SELECT
    a.*,
    a.related_govt_units = 'Yes'                         AS is_related_govt_unit,
    STARTS_WITH(UPPER(COALESCE(a.character, '')), 'TRANSFER ADJUSTMENT')
                                                       AS is_transfer_adjustment,
    UPPER(COALESCE(a.character, '')) LIKE '%TRANSFER%'   AS is_transfer_character,
    CURRENT_DATE('America/Los_Angeles') > DATE(a.fiscal_year, 6, 30)
                                                       AS is_fiscal_year_complete
    ,
    n.display_name                     AS department_display_name,
    n.provenance                       AS department_display_name_provenance
FROM actuals a
LEFT JOIN dept_names n
    ON n.department_code = a.department_code
