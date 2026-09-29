{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}

/*
  Staging: REI — taux de fiscalité directe locale, une ligne par commune × année.
  code_insee = département (2 caractères, 2A/2B pour la Corse, 97x pour
  l'outre-mer où DEP vaut « 97 » et COM commence par le chiffre du DOM) + commune.
*/

SELECT
    annee,
    CASE
        WHEN dep IN ('2A', '2B') THEN CONCAT(dep, LPAD(com, 3, '0'))
        WHEN dep = '97' THEN CONCAT('97', LPAD(com, 3, '0'))
        ELSE CONCAT(LPAD(dep, 2, '0'), LPAD(com, 3, '0'))
    END                         AS code_insee,
    libcom                      AS commune_nom,
    NULLIF(siren_epci, '')      AS siren_epci,
    NULLIF(nom_epci, '')        AS nom_epci,
    tfb_commune,
    tfb_commune_vote,
    tfb_epci,
    tfnb_commune
FROM {{ source('national_raw', 'rei_taux') }}
WHERE dep IS NOT NULL AND com IS NOT NULL
