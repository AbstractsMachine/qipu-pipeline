{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}

/*
  Staging : inventaire SRU, une ligne par commune soumise à la loi et par
  inventaire (sync_sru_inventaire.py, jeu « Communes et inventaire SRU » du
  ministère de la Transition écologique, data.gouv.fr).

  `annee_inventaire` = l'année du 1er janvier auquel les logements sont
  décomptés (le fichier « 2026 » donne l'inventaire au 1er janvier 2025).
  Taux en pourcentage, tels que publiés : le fichier 2025 écrit 2 126 % pour
  Gap (21,26 %) et plus de 100 % pour Pointe-à-Pitre ; le test d'avertissement
  du schéma les signale, rien ne les corrige ici.
*/

SELECT
    SAFE_CAST(annee_inventaire AS INT64)  AS annee_inventaire,
    CAST(code_insee AS STRING)            AS code_insee,
    CAST(nom AS STRING)                   AS nom,
    SAFE_CAST(population AS INT64)        AS population,
    SAFE_CAST(nb_lls AS INT64)            AS nb_lls,
    SAFE_CAST(taux_sru AS FLOAT64)        AS taux_sru,
    SAFE_CAST(taux_cible AS FLOAT64)      AS taux_cible,
    SAFE_CAST(deficitaire AS BOOL)        AS deficitaire,
    SAFE_CAST(carencee AS BOOL)           AS carencee,
    SAFE_CAST(exemptee AS BOOL)           AS exemptee,
    CAST(fichier AS STRING)               AS fichier,
    CAST(source_url AS STRING)            AS source_url
FROM {{ source('national_raw', 'sru_inventaire') }}
