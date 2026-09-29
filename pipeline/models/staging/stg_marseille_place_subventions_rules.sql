-- =============================================================================
-- Staging: règles place ↔ subventions (lieux Marseille) — wrapper du seed
--
-- Source: seeds/cities/marseille/seed_marseille_place_subventions_rules.csv
-- Grain:  place_slug × relation (operator | residents).
-- Config éditoriale (regex + seuils), pas de donnée observée.
-- =============================================================================

{{ config(materialized='view', schema='staging', tags=['staging', 'seed-wrapper', 'marseille']) }}

SELECT
    place_slug,
    relation,
    match_regex,
    NULLIF(exclude_regex, '')  AS exclude_regex,
    min_montant_total,
    max_rows,
    note
FROM {{ ref('seed_marseille_place_subventions_rules') }}
