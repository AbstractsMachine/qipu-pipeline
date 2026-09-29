-- =============================================================================
-- Mart: US public debt series — export shape for the debt time-machine
--
-- Source: core_us_debt (+ core_us_fiscaldata_source_catalog for provenance).
-- Grain:  (series, record_date), three series:
--   - 'annual_fy_end' : fiscal-year-end totals 1790 → latest closed FY
--                       (Historical Debt Outstanding)
--   - 'month_end'     : last business day per calendar month, 1993-04 →
--                       (downsampled from Debt to the Penny — the full
--                       daily series stays queryable in core_us_debt)
--   - 'latest'        : the single most recent daily observation
--
-- Amounts in DOLLARS. The annual and daily-based series treat FFB debt
-- differently (per the datasets' published notes) — never splice them
-- into one continuous line.
-- =============================================================================

WITH provenance AS (
    SELECT DISTINCT
        source_id,
        dataset_title,
        table_name,
        dataset_page_url,
        endpoint,
        update_frequency
    FROM {{ ref('core_us_fiscaldata_source_catalog') }}
    WHERE source_id IN ('debt_to_penny', 'debt_outstanding')
),

annual AS (
    SELECT
        'annual_fy_end'          AS series,
        record_date,
        fiscal_year,
        debt_held_public_amt,
        intragov_hold_amt,
        tot_pub_debt_out_amt,
        'debt_outstanding'       AS source_id
    FROM {{ ref('core_us_debt') }}
    WHERE series = 'annual_fy_end'
),

month_end AS (
    SELECT
        'month_end'              AS series,
        record_date,
        fiscal_year,
        debt_held_public_amt,
        intragov_hold_amt,
        tot_pub_debt_out_amt,
        'debt_to_penny'          AS source_id
    FROM {{ ref('core_us_debt') }}
    WHERE series = 'daily'
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY EXTRACT(YEAR FROM record_date), EXTRACT(MONTH FROM record_date)
        ORDER BY record_date DESC
    ) = 1
),

latest AS (
    SELECT
        'latest'                 AS series,
        record_date,
        fiscal_year,
        debt_held_public_amt,
        intragov_hold_amt,
        tot_pub_debt_out_amt,
        'debt_to_penny'          AS source_id
    FROM {{ ref('core_us_debt') }}
    WHERE series = 'daily'
    QUALIFY ROW_NUMBER() OVER (ORDER BY record_date DESC) = 1
),

unioned AS (
    SELECT * FROM annual
    UNION ALL
    SELECT * FROM month_end
    UNION ALL
    SELECT * FROM latest
)

SELECT
    u.series,
    u.record_date,
    u.fiscal_year,
    u.debt_held_public_amt,
    u.intragov_hold_amt,
    u.tot_pub_debt_out_amt,
    pr.dataset_title       AS source_name,
    pr.dataset_page_url    AS source_url,
    pr.endpoint            AS source_api_endpoint,
    pr.update_frequency    AS source_update_frequency,
    'USD'                  AS unit
FROM unioned u
INNER JOIN provenance pr
    ON pr.source_id = u.source_id
