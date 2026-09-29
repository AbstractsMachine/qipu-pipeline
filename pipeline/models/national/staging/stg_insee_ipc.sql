{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}
/*
  Staging: indice des prix à la consommation (Insee), un point par mois.
*/
SELECT
    CAST(serie AS STRING)                         AS serie,
    CAST(SUBSTR(periode, 1, 4) AS INT64)          AS annee,
    CAST(SUBSTR(periode, 6, 2) AS INT64)          AS mois,
    CAST(valeur AS FLOAT64)                       AS indice
FROM {{ source('national_raw', 'insee_ipc') }}
WHERE valeur IS NOT NULL
