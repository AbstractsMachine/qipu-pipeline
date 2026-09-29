{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}

/*
  Staging: Répertoire national des élus, conseillers municipaux.
  Une ligne = un élu. Colonnes non sensibles seulement (voir le sync).
*/

SELECT
    CASE
        WHEN SAFE_CAST(com_code AS INT64) IS NOT NULL
            THEN LPAD(CAST(SAFE_CAST(com_code AS INT64) AS STRING), 5, '0')
        ELSE com_code
    END                                          AS code_insee,
    com_name                                     AS commune_nom,
    dep_code, dep_name,
    nom, prenom,
    NULLIF(fonction, '')                         AS fonction,
    SAFE.PARSE_DATE('%Y-%m-%d', LEFT(date_debut_mandat, 10))   AS date_debut_mandat,
    SAFE.PARSE_DATE('%Y-%m-%d', LEFT(date_debut_fonction, 10)) AS date_debut_fonction
FROM {{ source('national_raw', 'rne_conseillers_municipaux') }}
WHERE com_code IS NOT NULL
