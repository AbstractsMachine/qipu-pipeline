-- =============================================================================
-- Intermediate: purchasing-authority family dimension — one row per authority
--
-- Source: core_us_sf_contracts (carries stg_us_sf_purchasing_authority_families
--         row-level). Grain: purchasing_authority, only classified ones.
-- =============================================================================

SELECT
    purchasing_authority,
    ANY_VALUE(purchasing_authority_family)  AS authority_family
FROM {{ ref('core_us_sf_contracts') }}
WHERE purchasing_authority_family IS NOT NULL
GROUP BY purchasing_authority
