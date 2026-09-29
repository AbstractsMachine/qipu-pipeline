-- =============================================================================
-- Staging: SICONFI DCA Anexo I-D — what a município paid, by nature (2026-09-23).
-- Grain: ano × município × grupo. grupo = the first two digits of the code
-- ('3.1' staff, '3.2' debt interest, '3.3' other current, '4.4' investment,
-- '4.5' financial investment, '4.6' debt repayment; '3.0' / '4.0' the totals).
-- 2017 writes the codes with one more « .00 »: the grupo reads the same.
-- =============================================================================

SELECT
    ano,
    id_municipio,
    sigla_uf,
    REGEXP_EXTRACT(portaria, r'^([34]\.[0-9])\.') AS grupo,
    conta,
    SUM(valor) AS pago
FROM {{ source('br_siconfi_raw', 'br_siconfi_despesas_natureza') }}
WHERE valor IS NOT NULL
GROUP BY 1, 2, 3, 4, 5
