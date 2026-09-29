-- =============================================================================
-- Mart: address faces — one row per street per block, with the lowest and
-- highest civic number the address register places on that block, split by
-- side (odd / even numbers), so an address resolves to the side of the street
-- it is on rather than the block across from it.
--
-- An address is on the face whose street matches, whose parity matches and
-- whose range holds its number — how the map's address search finds a block.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts', 'citymap']) }}

SELECT
    std_street,
    MOD(civic_int, 2)  AS parity,
    block_idx,
    MIN(civic_int)     AS civic_lo,
    MAX(civic_int)     AS civic_hi,
    COUNT(*)           AS n_addresses
FROM {{ ref('core_ca_vancouver_property_addresses') }}
WHERE block_idx IS NOT NULL AND civic_int IS NOT NULL AND std_street IS NOT NULL
GROUP BY 1, 2, 3
