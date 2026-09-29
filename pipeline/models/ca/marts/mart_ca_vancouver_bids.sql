-- =============================================================================
-- Mart: competitions — one row per bid_number, the entity a reader opens.
-- Rolls the responses up: how many bidders, how many awards, the awarded
-- total, the lowest/highest price offered. The description is the most
-- frequent one among the responses (lot-level variants exist: "Re-roofing
-- of Three Properties" vs "Weeks House"). award_year = year of the first
-- award (or of the first response when nothing was awarded).
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH cat AS (
    SELECT dataset_title, dataset_page_url, license_title, rows_updated_at
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
    WHERE source_id = 'awarded_contracts'
),

descr AS (
    SELECT bid_number, bid_description
    FROM (
        SELECT bid_number, bid_description,
               ROW_NUMBER() OVER (PARTITION BY bid_number ORDER BY COUNT(*) DESC, LENGTH(bid_description) DESC, bid_description) AS rn
        FROM {{ ref('core_ca_vancouver_contracts') }}
        WHERE bid_description IS NOT NULL
        GROUP BY bid_number, bid_description
    )
    WHERE rn = 1
),

agg AS (
    SELECT
        bid_number,
        ANY_VALUE(bid_type)                                   AS bid_type,
        ANY_VALUE(bid_type_group)                             AS bid_type_group,
        COUNT(*)                                              AS n_responses,
        COUNT(DISTINCT vendor_key)                            AS n_bidders,
        COUNTIF(is_awarded)                                   AS n_awarded,
        COUNT(DISTINCT IF(is_awarded, vendor_key, NULL))      AS n_winners,
        SUM(IF(is_awarded, counted_amount_cad, NULL))         AS awarded_total_cad,
        COUNTIF(is_awarded AND is_shared_amount)              AS n_awarded_shared,
        COUNTIF(is_awarded AND bid_amount_cad IS NULL)        AS n_awarded_unpriced,
        MIN(IF(bid_amount_cad > 0, bid_amount_cad, NULL))     AS lowest_bid_cad,
        MAX(bid_amount_cad)                                   AS highest_bid_cad,
        COUNTIF(bid_amount_cad IS NOT NULL)                   AS n_priced,
        MIN(award_date)                                       AS first_date,
        MAX(award_date)                                       AS last_date,
        COALESCE(MIN(IF(is_awarded, award_year, NULL)), MIN(award_year)) AS award_year
    FROM {{ ref('core_ca_vancouver_contracts') }}
    GROUP BY bid_number
)

SELECT
    a.bid_number,
    d.bid_description,
    a.bid_type, a.bid_type_group,
    a.n_responses, a.n_bidders, a.n_awarded, a.n_winners,
    a.awarded_total_cad, a.n_awarded_unpriced, a.n_awarded_shared,
    a.lowest_bid_cad, a.highest_bid_cad, a.n_priced,
    a.first_date, a.last_date, a.award_year,
    'CAD' AS unit,
    cat.dataset_title AS source_name, cat.dataset_page_url AS source_url,
    cat.license_title AS source_license, cat.rows_updated_at AS source_rows_updated_at
FROM agg a
LEFT JOIN descr d USING (bid_number)
CROSS JOIN cat
