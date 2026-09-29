-- Σ awarded amount at competition grain (mart_ca_vancouver_bids) must equal
-- Σ counted amount at response grain (core) to the cent — the rollup drops
-- nothing and double-counts nothing. Vendor totals are as printed beside each
-- vendor, so they exceed it by exactly the shared amounts repeated per winner.
WITH a AS (SELECT SUM(awarded_total_cad) AS s FROM {{ ref('mart_ca_vancouver_bids') }}),
     b AS (SELECT SUM(IF(is_awarded, counted_amount_cad, NULL)) AS s,
                  SUM(IF(is_awarded, bid_amount_cad, NULL)) AS printed FROM {{ ref('core_ca_vancouver_contracts') }}),
     v AS (SELECT SUM(awarded_total_cad) AS s FROM {{ ref('mart_ca_vancouver_vendors') }})
SELECT a.s, b.s, v.s FROM a, b, v WHERE ABS(a.s - b.s) > 0.01 OR ABS(v.s - b.printed) > 0.01
