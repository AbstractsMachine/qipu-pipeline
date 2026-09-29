{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}

/*
  Staging: Répertoire national des élus, versions archivées du fichier des
  maires (Wayback Machine, une capture par an de 2020 à 2025).
  Une ligne = un maire × une capture. Colonnes non sensibles seulement (voir
  le sync). snapshot_date = date de publication du fichier par le ministère ;
  source_url = l'adresse archivée exacte.
*/

SELECT
    code_insee,
    commune                                      AS commune_nom,
    nom, prenom,
    SAFE.PARSE_DATE('%Y-%m-%d', LEFT(date_debut_mandat, 10))   AS date_debut_mandat,
    SAFE.PARSE_DATE('%Y-%m-%d', LEFT(date_debut_fonction, 10)) AS date_debut_fonction,
    SAFE.PARSE_DATE('%Y-%m-%d', snapshot_date)   AS snapshot_date,
    source_url
FROM {{ source('national_raw', 'rne_maires_historique') }}
WHERE code_insee IS NOT NULL AND snapshot_date IS NOT NULL
