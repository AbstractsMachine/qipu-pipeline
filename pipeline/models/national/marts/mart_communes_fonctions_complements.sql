{{
  config(
    enabled=true,
    materialized='table',
    partition_by={'field': 'annee', 'data_type': 'int64', 'range': {'start': 2010, 'end': 2051, 'interval': 1}},
    cluster_by=['code_insee'],
    tags=['national', 'marts']
  )
}}

/*
  Mart : ce que mart_communes_fonctions ne porte pas (2026-09-25) — cellules
  fonction × compte, même grain, même périmètre (communes, budget principal,
  balance définitive), trois genres :

    equipement   — ce que la commune paie pour construire, rénover, s'équiper :
                   comptes 20 (hors 204), 21 et 23, débit net du crédit. Le 204
                   (subventions d'équipement versées : fonds de concours,
                   participation au syndicat d'énergie) est de l'argent donné à
                   d'autres pour LEURS équipements — la page le dit à part.
                   C'est la « section d'investissement par politique » de la
                   page commune : sans elle, « Sur 100 € » ne montrait que le
                   fonctionnement, et « Ce qu'elle construit » une phrase.
    credit_64    — les remboursements sur rémunérations (crédits des comptes 64 :
                   indemnités journalières, mises à disposition refacturées).
                   mart_communes_fonctions garde le DÉBIT seul, dont les sommes
                   sont figées au centime ; l'export les soustrait des salaires
                   quand il présente une politique « nette », comme l'OFGL et
                   core_budget_national.
    remb_capital — le capital des emprunts remboursé (16 hors 165 dépôts et
                   cautionnements, 166 refinancements, 16449 opérations de
                   tirage sur ligne de trésorerie) : sans lui, la barre des 100 €
                   ne retombe pas sur le total des dépenses.

  Toutes les années : l'export lit l'année N et l'année N−1, pour dire
  l'évolution d'une politique sans rouvrir un autre fichier.

  Les montants négatifs sont gardés (annulations sur exercices antérieurs) :
  c'est à l'affichage de ne pas dessiner de barre, jamais au mart d'écarter.
*/

{{ fonctions_complements("'Commune', 'PARIS'", 'code_insee', reelles=false) }}
