-- =============================================================================
-- Core: place ↔ prime contract links (Block 6C)
--
-- Source: stg_us_sf_place_contracts (reviewed seed: prime contracts whose
--         title names the place, with the contract's agreed / lifetime-paid $
--         as frozen at review time).
-- Grain:  place_slug × contract_no.
--
-- Feeds the place capital rows (mart_us_sf_place_capital) and the payee chain
-- (mart_us_sf_place_payees joins core_us_sf_vouchers on contract_no).
-- =============================================================================

SELECT *
FROM {{ ref('stg_us_sf_place_contracts') }}
