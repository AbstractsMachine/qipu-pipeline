-- =============================================================================
-- Mart: the contracts register by award year — competitions posted, awards
-- made, awarded total, bidders per competition. is_partial = the current
-- calendar year (the register is appended through the year), so the chart
-- hatches it rather than reading it as a drop.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH cat AS (
    SELECT dataset_title, dataset_page_url, license_title, rows_updated_at
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
    WHERE source_id = 'awarded_contracts'
),

bids AS (
    SELECT bid_number, award_year, bid_type_group, n_bidders, n_awarded, awarded_total_cad
    FROM {{ ref('mart_ca_vancouver_bids') }}
),

yr AS (
    SELECT
        award_year,
        COUNT(*)                                     AS n_competitions,
        SUM(n_awarded)                               AS n_awards,
        COUNTIF(n_awarded = 0)                       AS n_competitions_unawarded,
        SUM(awarded_total_cad)                       AS awarded_total_cad,
        APPROX_QUANTILES(n_bidders, 2)[OFFSET(1)]    AS median_bidders,
        AVG(n_bidders)                               AS mean_bidders,
        COUNTIF(n_bidders = 1)                       AS n_single_bidder
    FROM bids
    GROUP BY award_year
),

by_group AS (
    SELECT award_year,
           ARRAY_AGG(STRUCT(bid_type_group, n, awarded_total_cad) ORDER BY n DESC) AS by_type
    FROM (
        SELECT award_year, bid_type_group, COUNT(*) AS n, SUM(awarded_total_cad) AS awarded_total_cad
        FROM bids
        GROUP BY award_year, bid_type_group
    )
    GROUP BY award_year
)

SELECT
    y.award_year,
    y.n_competitions, y.n_awards, y.n_competitions_unawarded, y.awarded_total_cad,
    y.median_bidders, y.mean_bidders, y.n_single_bidder,
    y.award_year = EXTRACT(YEAR FROM CURRENT_DATE()) AS is_partial,
    g.by_type,
    'CAD' AS unit,
    cat.dataset_title AS source_name, cat.dataset_page_url AS source_url,
    cat.license_title AS source_license, cat.rows_updated_at AS source_rows_updated_at
FROM yr y
LEFT JOIN by_group g USING (award_year)
CROSS JOIN cat
