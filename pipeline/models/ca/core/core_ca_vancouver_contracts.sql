-- =============================================================================
-- Core: bid responses OBT — one row per BIDDER per COMPETITION (not per
-- contract). The City's "Awarded contracts" dataset lists every response the
-- City received on every posted competition (bid_number), with awarded =
-- Yes/No per bidder. 2,573 of 6,414 rows are awards; the rest are losing
-- bids WITH their price — a competition signal Paris's DECP never publishes.
--
--   response_id  : surrogate key over the natural grain (bid_number, vendor,
--                  award_date, awarded, amount, description). Two source rows
--                  are exact duplicates but for a description variant; the
--                  description is part of the key so nothing is dropped and
--                  Σ amount still matches staging (assert_ca_contracts_sum).
--   is_awarded   : awarded = 'Yes' (N/A and Non Compliant read as not awarded).
--   bid_type_group: the register spells one procedure several ways
--                  ("Request for Quote" / "Request for Quotation"); grouped
--                  into five readable procedures for the mix chart.
--   vendor_key   : lowercase, punctuation-collapsed name — merges spelling
--                  variants ("TELUS" / "Telus") into one vendor fiche.
--   n_sharing_winners / is_shared_amount / counted_amount_cad: 18 competitions
--                  print ONE amount, to the cent, beside 2–6 different winners
--                  on the same award date ("Supply and Delivery of Light and
--                  Medium Duty Vehicles": $43,102,035 × 3 vendors) — a shared
--                  ceiling repeated per winner, not three contracts of that
--                  size ($128M of $1.98B measured 2026-09-13). The register
--                  does not say how it splits. So totals count it ONCE:
--                  counted_amount_cad is the amount for the first winner of
--                  the group (by vendor_key) and 0 for the others; each
--                  winner's row keeps bid_amount_cad as printed and the flag.
-- Σ bid_amount_cad == staging Σ (tests/ca/assert_ca_contracts_sum.sql).
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

WITH r AS (
SELECT
    {{ dbt_utils.generate_surrogate_key(['bid_number', 'vendor_name', 'award_date', 'awarded', 'bid_amount_cad', 'bid_description']) }}
                                                    AS response_id,
    bid_number,
    bid_type,
    CASE
        WHEN bid_type LIKE 'Request for Proposal%'        THEN 'RFP'
        WHEN bid_type LIKE 'Invitation to Tender%'        THEN 'ITT'
        WHEN bid_type LIKE 'Request for Quot%'            THEN 'RFQ'
        WHEN bid_type LIKE 'Request for Application%'
          OR bid_type LIKE 'RFA%'                         THEN 'RFA'
        WHEN bid_type LIKE '%Expression of Interest%'
          OR bid_type LIKE 'Express. of Interest%'        THEN 'RFEOI'
        ELSE 'OTHER'
    END                                                 AS bid_type_group,
    bid_description,
    award_date,
    EXTRACT(YEAR FROM award_date)                       AS award_year,
    vendor_name,
    REGEXP_REPLACE(REGEXP_REPLACE(LOWER(TRIM(vendor_name)), r'[^a-z0-9]+', '-'), r'^-|-$', '')
                                                    AS vendor_key,
    bid_amount_cad,
    awarded,
    awarded = 'Yes'                                     AS is_awarded,
    _synced_at
FROM {{ ref('stg_ca_vancouver_awarded_contracts') }}
),

shared AS (
    SELECT bid_number, award_date, bid_amount_cad, COUNT(DISTINCT vendor_key) AS n_sharing_winners
    FROM r
    WHERE is_awarded AND bid_amount_cad IS NOT NULL
    GROUP BY 1, 2, 3
)

SELECT
    r.*,
    COALESCE(sh.n_sharing_winners, 0)                   AS n_sharing_winners,
    COALESCE(sh.n_sharing_winners, 0) > 1               AS is_shared_amount,
    CASE
        WHEN NOT r.is_awarded OR COALESCE(sh.n_sharing_winners, 0) <= 1 THEN r.bid_amount_cad
        WHEN ROW_NUMBER() OVER (PARTITION BY r.bid_number, r.award_date, r.bid_amount_cad, r.is_awarded
                                ORDER BY r.vendor_key, r.response_id) = 1 THEN r.bid_amount_cad
        ELSE 0
    END                                                 AS counted_amount_cad
FROM r
LEFT JOIN shared sh
  ON r.is_awarded AND sh.bid_number = r.bid_number AND sh.award_date IS NOT DISTINCT FROM r.award_date
 AND sh.bid_amount_cad = r.bid_amount_cad
