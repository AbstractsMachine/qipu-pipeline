-- =============================================================================
-- Staging: the three local taxes a município collects (2026-09-23): IPTU
-- (property), ISS (services), ITBI (property transfers). Gross realized minus
-- the « other deductions » (refunds), at the tax's own top line.
--
-- The rows were taken by name (codes changed in 2018), so each tax arrives at
-- several levels (the tax, then principal / fines / arrears…). The top line is
-- the row whose code has the fewest non-zero segments.
-- =============================================================================

WITH tagged AS (
    SELECT
        ano, id_municipio, sigla_uf, estagio, portaria, valor,
        CASE
            WHEN UPPER(conta) LIKE '%PROPRIEDADE PREDIAL%' THEN 'iptu'
            WHEN UPPER(conta) LIKE '%SERVIÇOS DE QUALQUER NATUREZA%' THEN 'iss'
            WHEN UPPER(conta) LIKE '%INTER VIVOS%' THEN 'itbi'
        END AS imposto,
        ARRAY_LENGTH(ARRAY(SELECT x FROM UNNEST(SPLIT(portaria, '.')) x WHERE REGEXP_CONTAINS(x, r'[1-9]'))) AS profundidade
    FROM {{ source('br_siconfi_raw', 'br_siconfi_impostos') }}
    WHERE valor IS NOT NULL
),
topo AS (
    SELECT *
    FROM tagged
    WHERE imposto IS NOT NULL
    QUALIFY profundidade = MIN(profundidade) OVER (PARTITION BY ano, id_municipio, imposto, estagio)
)
SELECT
    ano, id_municipio, sigla_uf, imposto,
    SUM(IF(estagio = 'Receitas Brutas Realizadas', valor, 0))
      - SUM(IF(estagio = 'Outras Deduções da Receita', valor, 0)) AS liquida
FROM topo
GROUP BY 1, 2, 3, 4
