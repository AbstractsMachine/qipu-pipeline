-- =============================================================================
-- Staging: place ↔ public-works crosswalk — typed, one-to-one with raw
--
-- Source: raw.br_recife_place_obras (scripts/enrich/build_recife_place_obras.py:
--         works contracts matched to a facility by distinctive-name mention in
--         the objeto). Grain: one row per place slug.
-- Evidence only ("obra-mentions"), never "total spent at the place".
-- =============================================================================

SELECT
    slug,
    obras_total,
    n_obras,
    _synced_at
FROM {{ source('br_recife_raw', 'br_recife_place_obras') }}
