-- =============================================================================
-- Mart: vendors — one row per vendor_key (spelling variants merged), the
-- "who the City buys from" entity. Won/lost record across competitions,
-- awarded total, first/last year seen. display name = the most frequent
-- spelling. Organisations only: the City publishes company names.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH cat AS (
    SELECT dataset_title, dataset_page_url, license_title, rows_updated_at
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
    WHERE source_id = 'awarded_contracts'
),

names AS (
    SELECT vendor_key, vendor_name
    FROM (
        SELECT vendor_key, vendor_name,
               ROW_NUMBER() OVER (PARTITION BY vendor_key ORDER BY COUNT(*) DESC, vendor_name) AS rn
        FROM {{ ref('core_ca_vancouver_contracts') }}
        GROUP BY vendor_key, vendor_name
    )
    WHERE rn = 1
),

agg AS (
    SELECT
        vendor_key,
        COUNT(DISTINCT vendor_name)                       AS n_spellings,
        COUNT(*)                                          AS n_responses,
        COUNT(DISTINCT bid_number)                        AS n_competitions,
        COUNT(DISTINCT IF(is_awarded, bid_number, NULL))  AS n_competitions_won,
        COUNTIF(is_awarded)                               AS n_awards,
        -- as printed beside this vendor; a shared amount (core) is in every
        -- sharing winner's total — n_awards_shared says how many
        SUM(IF(is_awarded, bid_amount_cad, NULL))         AS awarded_total_cad,
        COUNTIF(is_awarded AND is_shared_amount)          AS n_awards_shared,
        COUNTIF(is_awarded AND bid_amount_cad IS NULL)    AS n_awards_unpriced,
        MIN(award_year)                                   AS first_year,
        MAX(award_year)                                   AS last_year,
        MIN(IF(is_awarded, award_year, NULL))             AS first_award_year,
        MAX(IF(is_awarded, award_year, NULL))             AS last_award_year
    FROM {{ ref('core_ca_vancouver_contracts') }}
    GROUP BY vendor_key
)

SELECT
    a.vendor_key, n.vendor_name, a.n_spellings,
    a.n_responses, a.n_competitions, a.n_competitions_won, a.n_awards,
    a.awarded_total_cad, a.n_awards_unpriced,
    a.first_year, a.last_year, a.first_award_year, a.last_award_year,
    'CAD' AS unit,
    cat.dataset_title AS source_name, cat.dataset_page_url AS source_url,
    cat.license_title AS source_license, cat.rows_updated_at AS source_rows_updated_at
FROM agg a
JOIN names n USING (vendor_key)
CROSS JOIN cat
