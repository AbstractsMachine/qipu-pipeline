{{
  config(
    enabled=true,
    materialized='table',
    tags=['national', 'marts']
  )
}}

/*
  Mart: évolution pluriannuelle (OFGL, 7 ans)

  Trajectoire financière de chaque commune : dépenses/recettes de fonctionnement,
  épargne brute, encours de dette, dépenses d'équipement — par année et par
  habitant. Déterministe (OFGL), sans enrichissement.
*/

WITH ofgl AS (
    SELECT
        code_insee,
        commune_nom,
        annee,
        MAX(population) AS population,
        MAX(CASE WHEN agregat = 'Dépenses de fonctionnement' THEN montant END) AS depenses_fonctionnement,
        MAX(CASE WHEN agregat = 'Recettes de fonctionnement' THEN montant END) AS recettes_fonctionnement,
        MAX(CASE WHEN agregat = 'Epargne brute' THEN montant END)               AS epargne_brute,
        MAX(CASE WHEN agregat = 'Encours de dette' THEN montant END)            AS encours_dette,
        MAX(CASE WHEN agregat = "Dépenses d'équipement" THEN montant END)       AS depenses_equipement,
        -- Agrégats ajoutés le 2026-09-09 (sync --all-agregats) : ce que l'État
        -- verse, ce que la commune verse, ce que l'intercommunalité reverse.
        MAX(CASE WHEN agregat = 'Dotation globale de fonctionnement' THEN montant END) AS dgf,
        MAX(CASE WHEN agregat = "Concours de l'Etat" THEN montant END)                 AS concours_etat,
        MAX(CASE WHEN agregat = 'Subventions aux personnes de droit privé' THEN montant END) AS subventions_versees,
        MAX(CASE WHEN agregat = "Subventions d'équipement versées" THEN montant END)   AS subventions_equipement_versees,
        MAX(CASE WHEN agregat = 'Fiscalité reversée' THEN montant END)                 AS fiscalite_reversee,
        MAX(CASE WHEN agregat = 'Impôts locaux' THEN montant END)                      AS impots_locaux,
        MAX(CASE WHEN agregat = 'Frais de personnel' THEN montant END)                 AS frais_personnel,
        MAX(CASE WHEN agregat = 'Achats et charges externes' THEN montant END)         AS achats_charges_externes,
        MAX(CASE WHEN agregat = "Taxe d'enlévement des ordures ménagères" THEN montant END) AS teom,
        MAX(CASE WHEN agregat = 'Dépenses totales' THEN montant END)                   AS depenses_totales,
        MAX(CASE WHEN agregat = 'Recettes totales' THEN montant END)                   AS recettes_totales
    FROM {{ ref('stg_ofgl_communes') }}
    GROUP BY code_insee, commune_nom, annee
)

SELECT
    code_insee,
    commune_nom,
    annee,
    population,
    depenses_fonctionnement,
    recettes_fonctionnement,
    epargne_brute,
    encours_dette,
    depenses_equipement,
    dgf,
    concours_etat,
    subventions_versees,
    subventions_equipement_versees,
    fiscalite_reversee,
    impots_locaux,
    frais_personnel,
    achats_charges_externes,
    teom,
    depenses_totales,
    recettes_totales,
    SAFE_DIVIDE(depenses_fonctionnement, population) AS depenses_fonctionnement_hab,
    SAFE_DIVIDE(recettes_fonctionnement, population) AS recettes_fonctionnement_hab,
    SAFE_DIVIDE(encours_dette, population)           AS encours_dette_hab,
    SAFE_DIVIDE(encours_dette, NULLIF(epargne_brute, 0)) AS capacite_desendettement
FROM ofgl
WHERE population > 0
