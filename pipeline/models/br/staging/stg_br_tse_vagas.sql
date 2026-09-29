-- Staging: council seats (vereadores) per município, 2024 (TSE, 2026-09-23).
SELECT id_municipio, SAFE_CAST(vagas AS INT64) AS vereadores
FROM {{ source('br_siconfi_raw', 'br_tse_vagas') }}
WHERE id_municipio IS NOT NULL
