{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}
/*
  Staging: SIRENE, établissements sièges (INSEE) — une ligne par SIREN.
  La commune du siège et son code postal ; jamais l'adresse de rue. Quand
  l'INSEE a gardé plusieurs sièges (un fermé, un actif), on garde l'actif.
*/
SELECT
    CAST(siren AS STRING)            AS siren,
    CAST(code_commune AS STRING)     AS code_commune,
    CAST(libelle_commune AS STRING)  AS libelle_commune,
    CAST(code_postal AS STRING)      AS code_postal,
    CAST(etat_administratif AS STRING) AS etat_administratif
FROM {{ source('national_raw', 'sirene_sieges') }}
WHERE siren IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY siren ORDER BY IF(etat_administratif = 'A', 0, 1)) = 1
