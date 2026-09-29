-- =============================================================================
-- Mart: what municípios of the same size spend per inhabitant (2026-09-23) —
-- the « ailleurs » of the French commune page. For each year and size band,
-- the median per inhabitant of the total paid and of each função, among the
-- municípios of the band that report the função.
--
-- Bands (population, IBGE estimate of the year when there is one, else the
-- latest): < 5 000, 5–10 000, 10–20 000, 20–50 000, 50–100 000, 100–300 000,
-- 300 000–1 million, > 1 million. National, as the French bands are.
-- =============================================================================

WITH pop AS (
    SELECT id_municipio, ano, populacao
    FROM {{ source('br_siconfi_raw', 'br_ibge_populacao') }}
    WHERE populacao IS NOT NULL AND populacao > 0
),
latest AS (
    SELECT id_municipio, populacao FROM {{ ref('core_br_municipios') }} WHERE populacao > 0
),
d AS (
    SELECT
        x.id_municipio, x.ano, x.funcao_codigo, x.pago,
        COALESCE(p.populacao, l.populacao) AS populacao
    FROM {{ ref('core_br_municipio_despesas') }} x
    LEFT JOIN pop p USING (id_municipio, ano)
    LEFT JOIN latest l USING (id_municipio)
    WHERE x.subfuncao_codigo = '000' AND x.pago > 0
),
banded AS (
    SELECT
        *,
        CASE
            WHEN populacao < 5000 THEN 1 WHEN populacao < 10000 THEN 2 WHEN populacao < 20000 THEN 3
            WHEN populacao < 50000 THEN 4 WHEN populacao < 100000 THEN 5 WHEN populacao < 300000 THEN 6
            WHEN populacao < 1000000 THEN 7 ELSE 8
        END AS faixa,
        pago / populacao AS pago_hab
    FROM d
    WHERE populacao > 0
)

SELECT
    ano,
    faixa,
    funcao_codigo,
    COUNT(*) AS n_municipios,
    APPROX_QUANTILES(pago_hab, 100)[OFFSET(50)] AS mediana_hab
FROM banded
GROUP BY 1, 2, 3
