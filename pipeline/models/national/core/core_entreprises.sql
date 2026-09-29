{{
  config(
    enabled=true,
    materialized='table',
    cluster_by=['siren'],
    tags=['national', 'core']
  )
}}
/*
  Core: une ligne par entreprise (SIREN), ce que la fiche d'un fournisseur de
  commune dit d'elle (2026-09-25) : son nom, son activité en clair, sa taille,
  la commune de son siège. `est_personne_physique` suit la règle du site : un
  entrepreneur individuel n'est jamais affiché nommément.

  La tranche d'effectifs est écrite comme l'INSEE la définit (salariés au
  31 décembre, dernière année connue) ; « NN » (non employeuse ou inconnue)
  reste vide plutôt que de dire « 0 salarié » à tort.
*/
SELECT
    u.siren,
    u.denomination,
    u.categorie_juridique,
    u.est_personne_physique,
    u.etat_administratif,
    u.categorie_entreprise,
    u.activite_principale,
    n.libelle_naf                                   AS libelle_activite,
    u.tranche_effectifs                             AS tranche_effectifs_code,
    CASE u.tranche_effectifs
        WHEN '00' THEN '0 salarié'
        WHEN '01' THEN '1 ou 2 salariés'
        WHEN '02' THEN '3 à 5 salariés'
        WHEN '03' THEN '6 à 9 salariés'
        WHEN '11' THEN '10 à 19 salariés'
        WHEN '12' THEN '20 à 49 salariés'
        WHEN '21' THEN '50 à 99 salariés'
        WHEN '22' THEN '100 à 199 salariés'
        WHEN '31' THEN '200 à 249 salariés'
        WHEN '32' THEN '250 à 499 salariés'
        WHEN '41' THEN '500 à 999 salariés'
        WHEN '42' THEN '1 000 à 1 999 salariés'
        WHEN '51' THEN '2 000 à 4 999 salariés'
        WHEN '52' THEN '5 000 à 9 999 salariés'
        WHEN '53' THEN '10 000 salariés et plus'
    END                                             AS tranche_effectifs,
    s.code_commune                                  AS siege_code_commune,
    s.libelle_commune                               AS siege_commune,
    s.code_postal                                   AS siege_code_postal
FROM {{ ref('stg_sirene_unites_legales') }} u
LEFT JOIN {{ ref('stg_sirene_sieges') }} s USING (siren)
LEFT JOIN {{ ref('stg_naf_rev2') }} n ON n.code_naf = u.activite_principale
