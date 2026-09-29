{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}

/*
  Staging: SIRENE unités légales (INSEE)

  Une ligne par SIREN. `est_personne_physique` = catégorie juridique 1000
  (entrepreneur individuel) : un titulaire de marché dans ce cas ne reçoit
  jamais de fiche ni d'affichage nominatif.
*/

SELECT
    CAST(siren AS STRING)                     AS siren,
    CAST(categorie_juridique AS STRING)       AS categorie_juridique,
    CAST(categorie_juridique AS STRING) = '1000' AS est_personne_physique,
    CAST(etat_administratif AS STRING)        AS etat_administratif,
    CAST(denomination AS STRING)              AS denomination,
    CAST(activite_principale AS STRING)       AS activite_principale,
    CAST(categorie_entreprise AS STRING)      AS categorie_entreprise,
    CAST(tranche_effectifs AS STRING)         AS tranche_effectifs
FROM {{ source('national_raw', 'sirene_unites_legales') }}
WHERE siren IS NOT NULL
