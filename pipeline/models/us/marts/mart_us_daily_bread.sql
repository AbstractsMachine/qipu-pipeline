-- =============================================================================
-- Mart: US national daily-bread — latest closed month, receipts by source
--       + outlays by function
--
-- Sources: core_us_receipts_by_source + core_us_outlays_by_function
--          (MTS Table 9 verified detail recipes), core_us_population
--          (per-resident scaling), core_us_fiscaldata_source_catalog (provenance —
--          same pattern as the stg_mapping_* dimension refs on the Paris
--          side).
-- Grain:  (side, row_type, category) for the latest record_date.
--
-- row_type 'detail' = the 9 receipt sources / 19 budget functions;
-- row_type 'total'  = Σ(detail) per side. The tests/us/ identity tests
-- guarantee Σ(detail) equals the published MTS T-rows (Table 9 §1.8 /
-- §2.20 and Table 5 'Total Outlays'), so these totals ARE the published
-- totals — asserted, not assumed.
--
-- All amounts CASH, DOLLARS. FYTD figures run through
-- months_into_fiscal_year months of the fiscal year (Oct=1).
-- =============================================================================

WITH latest AS (
    SELECT MAX(record_date) AS record_date
    FROM {{ ref('core_us_receipts_by_source') }}
),

pop AS (
    SELECT year, as_of_date, population, source, source_url
    FROM {{ ref('core_us_population') }}
    QUALIFY ROW_NUMBER() OVER (ORDER BY year DESC) = 1
),

provenance AS (
    SELECT DISTINCT
        dataset_title,
        table_name,
        dataset_page_url,
        endpoint,
        update_frequency
    FROM {{ ref('core_us_fiscaldata_source_catalog') }}
    WHERE source_id = 'mts_table_9'
),

receipts_detail AS (
    SELECT
        r.record_date,
        r.fiscal_year,
        r.months_into_fiscal_year,
        'receipts'                   AS side,
        'detail'                     AS row_type,
        r.source_desc                AS category,
        r.line_code_nbr,
        r.current_month_receipt_amt  AS current_month_amt,
        r.current_fytd_receipt_amt   AS current_fytd_amt,
        r.prior_fytd_receipt_amt     AS prior_fytd_amt
    FROM {{ ref('core_us_receipts_by_source') }} r
    INNER JOIN latest USING (record_date)
),

outlays_detail AS (
    SELECT
        o.record_date,
        o.fiscal_year,
        o.months_into_fiscal_year,
        'outlays'                    AS side,
        'detail'                     AS row_type,
        o.function_desc              AS category,
        o.line_code_nbr,
        o.current_month_outlay_amt   AS current_month_amt,
        o.current_fytd_outlay_amt    AS current_fytd_amt,
        o.prior_fytd_outlay_amt      AS prior_fytd_amt
    FROM {{ ref('core_us_outlays_by_function') }} o
    INNER JOIN latest USING (record_date)
),

detail AS (
    SELECT * FROM receipts_detail
    UNION ALL
    SELECT * FROM outlays_detail
),

totals AS (
    SELECT
        record_date,
        fiscal_year,
        months_into_fiscal_year,
        side,
        'total'                      AS row_type,
        'Total'                      AS category,
        CAST(NULL AS STRING)         AS line_code_nbr,
        SUM(current_month_amt)       AS current_month_amt,
        SUM(current_fytd_amt)        AS current_fytd_amt,
        SUM(prior_fytd_amt)          AS prior_fytd_amt
    FROM detail
    GROUP BY record_date, fiscal_year, months_into_fiscal_year, side
),

unioned AS (
    SELECT * FROM detail
    UNION ALL
    SELECT * FROM totals
)

SELECT
    u.record_date,
    u.fiscal_year,
    u.months_into_fiscal_year,
    u.side,
    u.row_type,
    u.category,
    u.line_code_nbr,
    u.current_month_amt,
    u.current_fytd_amt,
    u.prior_fytd_amt,
    SAFE_DIVIDE(u.current_fytd_amt, t.current_fytd_amt)                     AS share_of_side_fytd,
    SAFE_DIVIDE(u.current_fytd_amt - u.prior_fytd_amt, ABS(u.prior_fytd_amt)) AS yoy_fytd_pct,
    SAFE_DIVIDE(u.current_fytd_amt, p.population)                           AS per_resident_fytd_usd,
    SAFE_DIVIDE(u.current_month_amt, p.population)                          AS per_resident_month_usd,
    p.population,
    p.year                     AS population_year,
    p.as_of_date               AS population_as_of,
    p.source                   AS population_source,
    p.source_url               AS population_source_url,
    pr.dataset_title           AS source_name,
    pr.table_name              AS source_table,
    pr.dataset_page_url        AS source_url,
    pr.endpoint                AS source_api_endpoint,
    pr.update_frequency        AS source_update_frequency,
    'USD'                      AS unit
FROM unioned u
INNER JOIN totals t
    ON t.side = u.side
CROSS JOIN pop p
CROSS JOIN provenance pr
