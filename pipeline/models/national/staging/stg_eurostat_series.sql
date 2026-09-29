{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}

/*
  Staging : Eurostat, une ligne par valeur (sync_eurostat_national.py).

  Cinq jeux : dette trimestrielle (gov_10q_ggdebt), prélèvements
  (gov_10a_taxag), dépenses COFOG (gov_10a_exp), dépenses par sous-secteur
  (gov_10a_main), PIB (nama_10_gdp). Une dimension absente d'un jeu est vide
  (NULL ici). `time` garde la forme Eurostat : « 2025 » ou « 2026-Q1 ».
*/

SELECT
    CAST(dataset AS STRING)             AS dataset,
    CAST(geo AS STRING)                 AS geo,
    CAST(time AS STRING)                AS periode,
    NULLIF(CAST(unit AS STRING), '')    AS unit,
    NULLIF(CAST(sector AS STRING), '')  AS sector,
    NULLIF(CAST(na_item AS STRING), '') AS na_item,
    NULLIF(CAST(cofog99 AS STRING), '') AS cofog99,
    SAFE_CAST(value AS FLOAT64)         AS valeur,
    -- la date de publication du jeu par Eurostat (« updated »), citée par les pages
    CAST(updated AS STRING)             AS eurostat_updated
FROM {{ source('national_raw', 'eurostat_series') }}
WHERE value IS NOT NULL
