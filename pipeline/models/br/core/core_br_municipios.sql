-- =============================================================================
-- Core: the municípios directory the marts join on — IBGE code, name, UF,
-- region, capital flag, latest population and the site's slug. One row per
-- município. The staging model does the reading ; the marts read this one
-- (layering rule E3 : a mart refs core, never staging).
-- =============================================================================

SELECT *
FROM {{ ref('stg_br_municipios') }}
