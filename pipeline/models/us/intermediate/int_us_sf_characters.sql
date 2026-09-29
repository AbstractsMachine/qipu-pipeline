-- =============================================================================
-- Intermediate: character gloss dimension — one row per (side, character)
--
-- Source: core_us_sf_budget (carries stg_us_sf_character_glosses row-level).
-- Grain: (side, character_code), only characters with a gloss.
-- =============================================================================

SELECT
    revenue_or_spending                          AS side,
    character_code,
    ANY_VALUE(character_gloss)                   AS gloss,
    ANY_VALUE(character_display_category)        AS display_category,
    ANY_VALUE(character_gloss_provenance)        AS provenance
FROM {{ ref('core_us_sf_budget') }}
WHERE character_gloss IS NOT NULL
GROUP BY 1, 2
