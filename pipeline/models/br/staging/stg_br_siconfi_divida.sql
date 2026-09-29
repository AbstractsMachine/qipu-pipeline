-- =============================================================================
-- Staging: loans and financing a município owes at year end (balance sheet,
-- DCA), 2026-09-23. prazo = 'curto' (2.1.2) or 'longo' (2.2.2).
-- =============================================================================

SELECT
    ano,
    id_municipio,
    sigla_uf,
    IF(STARTS_WITH(portaria, '2.1.'), 'curto', 'longo') AS prazo,
    SUM(valor) AS valor
FROM {{ source('br_siconfi_raw', 'br_siconfi_divida') }}
WHERE valor IS NOT NULL
GROUP BY 1, 2, 3, 4
