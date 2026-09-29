{{
  config(
    enabled=true,
    materialized='table',
    tags=['national', 'marts']
  )
}}

/*
  Mart: chantiers de la commune financés par l'État (Fonds vert).

  Règle d'attribution : le BÉNÉFICIAIRE est la commune elle-même — son SIREN
  (dimension OFGL) — et non un porteur simplement situé dans la commune (un
  projet parisien du 20e était codé Pantin dans le fichier source). Pour
  2023, sans SIRET, on accepte le code commune si le nom du bénéficiaire
  commence par « COMMUNE » ou « MAIRIE » ou « VILLE ».
*/

WITH communes AS (
    SELECT siren, code_insee, commune_nom
    FROM {{ ref('stg_ofgl_communes') }}
    QUALIFY ROW_NUMBER() OVER (PARTITION BY siren ORDER BY annee DESC) = 1
),

projets AS (
    SELECT * FROM {{ ref('stg_fonds_vert') }}
)

SELECT
    c.code_insee,
    c.commune_nom,
    p.annee,
    p.nom_projet,
    p.resume_projet,
    p.montant_engage,
    p.demarche,
    p.numero_dossier
FROM projets p
JOIN communes c
  ON (p.siren_beneficiaire IS NOT NULL AND p.siren_beneficiaire = c.siren)
  OR (p.siren_beneficiaire IS NULL AND p.code_insee = c.code_insee
      AND REGEXP_CONTAINS(UPPER(COALESCE(p.raison_sociale_beneficiaire, '')), r'^(COMMUNE|MAIRIE|VILLE)\b'))
