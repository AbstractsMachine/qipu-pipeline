{{
  config(
    enabled=true,
    materialized='table',
    cluster_by=['siren'],
    tags=['national', 'marts']
  )
}}
/*
  Mart: les entreprises titulaires d'au moins un marché public de commune
  (DECP), ce que leur fiche en dit (2026-09-25) — export_entreprises_identite.py
  en fait un fichier par tranche de SIREN. Jamais une personne physique.
*/
SELECT
    e.siren,
    e.denomination,
    e.libelle_activite,
    e.activite_principale,
    e.tranche_effectifs,
    e.categorie_entreprise,
    e.etat_administratif,
    e.siege_commune,
    e.siege_code_postal
FROM {{ ref('core_entreprises') }} e
WHERE NOT COALESCE(e.est_personne_physique, FALSE)
  AND e.siren IN (
      SELECT DISTINCT titulaire_siren
      FROM {{ ref('core_marches_national') }}
      WHERE titulaire_siren IS NOT NULL
  )
