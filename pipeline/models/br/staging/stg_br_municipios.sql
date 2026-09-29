-- =============================================================================
-- Staging: the 5 570 municípios — IBGE code, name, UF, region, latest
-- population estimate, and the site's slug (« olinda-pe »).
-- Sources: raw.br_bd_municipios + raw.br_ibge_populacao (copies of Base dos Dados, latest year per município).
-- =============================================================================

WITH pop AS (
    SELECT id_municipio, populacao, ano AS populacao_ano
    FROM {{ source('br_siconfi_raw', 'br_ibge_populacao') }}
    WHERE populacao IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY id_municipio ORDER BY ano DESC) = 1
)

SELECT
    d.id_municipio,
    d.nome,
    d.sigla_uf,
    d.nome_uf,
    d.nome_regiao,
    d.capital_uf,
    p.populacao,
    p.populacao_ano,
    CONCAT(
        REGEXP_REPLACE(
            REGEXP_REPLACE(LOWER(REGEXP_REPLACE(NORMALIZE(d.nome, NFD), r'\pM', '')), r'[^a-z0-9]+', '-'),
            r'^-+|-+$', ''
        ),
        '-', LOWER(d.sigla_uf)
    ) AS slug
FROM {{ source('br_siconfi_raw', 'br_bd_municipios') }} d
LEFT JOIN pop p USING (id_municipio)
