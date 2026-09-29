-- =============================================================================
-- Staging: the mayor elected in each município, 2012 / 2016 / 2020 / 2024
-- (TSE, 2026-09-23). One row per ano × município (the round that elected him
-- or her). The name is shown, never the party (editorial rule: no political
-- framing).
-- =============================================================================

SELECT
    ano,
    id_municipio,
    ARRAY_AGG(STRUCT(nome, nome_urna, genero) ORDER BY turno DESC LIMIT 1)[OFFSET(0)].*
FROM {{ source('br_siconfi_raw', 'br_tse_prefeitos') }}
WHERE id_municipio IS NOT NULL
GROUP BY 1, 2
