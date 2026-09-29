-- =============================================================================
-- Staging: vendor string → normalized payee — one-to-one with the seed
--
-- Source: seed_us_sf_payee_identity (build_sf_payee_identity.py: exact
--         core-name match + reviewed JV / predecessor merges).
-- Grain:  vendor (the raw Controller string). Identity only, no money.
-- =============================================================================

SELECT
    vendor,
    payee_slug,
    payee_name,
    core_key,
    NULLIF(merge_reason, '')  AS merge_reason,
    COALESCE(is_curated, FALSE) AS is_curated
FROM {{ ref('seed_us_sf_payee_identity') }}
