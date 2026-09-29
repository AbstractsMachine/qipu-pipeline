{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}

/*
  Staging: Fonds vert — un projet subventionné par l'État par ligne.
  `code_insee` : le code commune normalisé (zéros de tête).
*/

SELECT
    annee,
    nom_projet,
    NULLIF(resume_projet, '')            AS resume_projet,
    montant_engage,
    NULLIF(demarche, '')                 AS demarche,
    NULLIF(siren_beneficiaire, '')       AS siren_beneficiaire,
    NULLIF(raison_sociale_beneficiaire, '') AS raison_sociale_beneficiaire,
    NULLIF(forme_juridique_beneficiaire, '') AS forme_juridique_beneficiaire,
    CASE
        WHEN SAFE_CAST(code_commune AS INT64) IS NOT NULL
            THEN LPAD(CAST(SAFE_CAST(code_commune AS INT64) AS STRING), 5, '0')
        ELSE NULLIF(code_commune, '')
    END                                  AS code_insee,
    NULLIF(nom_commune, '')              AS nom_commune,
    NULLIF(numero_dossier, '')           AS numero_dossier
FROM {{ source('national_raw', 'fonds_vert') }}
WHERE montant_engage IS NOT NULL AND montant_engage > 0
