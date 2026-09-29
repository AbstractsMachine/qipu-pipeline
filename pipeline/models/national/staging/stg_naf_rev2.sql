{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}
/*
  Staging: nomenclature NAF rév. 2 (Insee), niveau 5 — code « 35.11Z » et son
  libellé. Sirene écrit l'activité principale au même format (« 35.11Z »).
*/
SELECT
    TRIM(code)     AS code_naf,
    TRIM(libelle)  AS libelle_naf
FROM {{ ref('seed_naf_rev2') }}
