{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}

/*
  Staging : budget de l'État, dépenses par destination (sync_etat_plf.py).
  Une ligne du jeu du ministère (action × titre…), réduite aux colonnes utiles,
  noms unifiés d'une année à l'autre par le chargeur.
*/

SELECT
    CAST(dataset_id AS STRING)          AS dataset_id,
    SAFE_CAST(exercice AS INT64)        AS exercice,
    CAST(loi AS STRING)                 AS loi,
    CAST(typebudget AS STRING)          AS typebudget,
    CAST(mission AS STRING)             AS mission,
    CAST(libelle_mission AS STRING)     AS libelle_mission,
    CAST(programme AS STRING)           AS programme,
    CAST(libelle_programme AS STRING)   AS libelle_programme,
    NULLIF(CAST(action AS STRING), '')         AS action,
    NULLIF(CAST(libelle_action AS STRING), '') AS libelle_action,
    SAFE_CAST(ae AS FLOAT64)            AS ae,
    SAFE_CAST(cp AS FLOAT64)            AS cp
FROM {{ source('national_raw', 'etat_plf') }}
