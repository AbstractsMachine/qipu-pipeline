-- Σ bid_amount_cad must survive stg → core to the cent. Fails on any drift.
WITH s AS (SELECT SUM(bid_amount_cad) AS t FROM {{ ref('stg_ca_vancouver_awarded_contracts') }}),
     c AS (SELECT SUM(bid_amount_cad) AS t FROM {{ ref('core_ca_vancouver_contracts') }})
SELECT s.t AS stg_total, c.t AS core_total
FROM s CROSS JOIN c
WHERE ABS(IFNULL(s.t, 0) - IFNULL(c.t, 0)) > 0.005
