-- =============================================================================
-- Core: Recife civic places — one row per facility with a stable slug
--
-- Sources: stg_br_recife_places (6 families unified with geo),
--          stg_br_recife_place_obras (additive: works contracts mentioning
--          the place — evidence, never a total).
-- Grain:  slug. Facilities without coordinates or name are dropped here (a
--         place the map cannot show has no fiche). Slug = normalised name,
--         suffixed by rank on (lat, lon) when several facilities share it.
-- =============================================================================

WITH valid AS (
    SELECT
        nome, familia, tipo, lat, lon, bairro, endereco, detalhe,
        NULLIF(REGEXP_REPLACE(
            REGEXP_REPLACE(LOWER(NORMALIZE(nome, NFD)), r'\p{Mn}', ''),
            r'[^a-z0-9]+', '-'), '') AS base_slug
    FROM {{ ref('stg_br_recife_places') }}
    WHERE lat IS NOT NULL AND lon IS NOT NULL AND nome IS NOT NULL
),

slugged AS (
    SELECT *,
        CASE WHEN COUNT(*) OVER (PARTITION BY base_slug) > 1
             THEN CONCAT(base_slug, '-', CAST(ROW_NUMBER() OVER (PARTITION BY base_slug ORDER BY lat, lon) AS STRING))
             ELSE base_slug END AS slug
    FROM valid
    WHERE base_slug IS NOT NULL
),

obras AS (
    SELECT slug, obras_total, n_obras
    FROM {{ ref('stg_br_recife_place_obras') }}
)

SELECT
    s.slug,
    s.nome,
    s.familia,
    s.tipo,
    s.lat,
    s.lon,
    s.bairro,
    s.endereco,
    s.detalhe,
    o.obras_total    AS ode_obras_total,
    o.n_obras        AS ode_n_obras
FROM slugged s
LEFT JOIN obras o ON o.slug = s.slug
