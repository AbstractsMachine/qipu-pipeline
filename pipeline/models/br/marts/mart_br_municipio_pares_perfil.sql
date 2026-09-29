-- =============================================================================
-- Mart: the debt and the local taxes of the municípios of the same size, per
-- inhabitant (2026-09-26) — the « Municípios do mesmo porte » under the page's
-- « Dívida e impostos », as the French page puts the strata median under its
-- debt and taxes. For each year and size band, the median per inhabitant of:
--   divida    the balance-sheet loans and financing (mart_br_municipio_perfil),
--             a município with none counted at zero;
--   impostos  ISS + IPTU + ITBI collected, net of deductions, among the
--             municípios that report at least one of the three.
-- The same definitions as the figures the page shows (perfil), the same bands
-- and population as mart_br_municipio_pares (IBGE estimate of the year when
-- there is one, else the latest).
-- =============================================================================

WITH pop AS (
    SELECT id_municipio, ano, populacao
    FROM {{ source('br_siconfi_raw', 'br_ibge_populacao') }}
    WHERE populacao IS NOT NULL AND populacao > 0
),
latest AS (
    SELECT id_municipio, populacao FROM {{ ref('core_br_municipios') }} WHERE populacao > 0
),
p AS (
    SELECT
        x.id_municipio, x.ano, x.divida,
        IF(COALESCE(x.iss, 0) + COALESCE(x.iptu, 0) + COALESCE(x.itbi, 0) > 0,
           COALESCE(x.iss, 0) + COALESCE(x.iptu, 0) + COALESCE(x.itbi, 0), NULL) AS impostos,
        COALESCE(pp.populacao, l.populacao) AS populacao
    FROM {{ ref('mart_br_municipio_perfil') }} x
    LEFT JOIN pop pp USING (id_municipio, ano)
    LEFT JOIN latest l USING (id_municipio)
),
banded AS (
    SELECT
        id_municipio, ano, divida, impostos, populacao,
        CASE
            WHEN populacao < 5000 THEN 1 WHEN populacao < 10000 THEN 2 WHEN populacao < 20000 THEN 3
            WHEN populacao < 50000 THEN 4 WHEN populacao < 100000 THEN 5 WHEN populacao < 300000 THEN 6
            WHEN populacao < 1000000 THEN 7 ELSE 8
        END AS faixa
    FROM p
    WHERE populacao > 0
),
long AS (
    SELECT ano, faixa, 'divida' AS serie, divida / populacao AS valor_hab FROM banded WHERE divida IS NOT NULL
    UNION ALL
    SELECT ano, faixa, 'impostos' AS serie, impostos / populacao AS valor_hab FROM banded WHERE impostos IS NOT NULL
)

SELECT
    ano,
    faixa,
    serie,
    COUNT(*) AS n_municipios,
    APPROX_QUANTILES(valor_hab, 100)[OFFSET(50)] AS mediana_hab
FROM long
GROUP BY 1, 2, 3
