{{
  config(
    enabled=true,
    materialized='table',
    cluster_by=['code_insee'],
    tags=['national', 'marts']
  )
}}

/*
  Mart: lignes budget national par nature (source d'export)

  Une ligne = (commune × année × section × sens × groupe sankey × catégorie).
  L'exporteur (export_budget_national.py) lit ces lignes filtrées par code_insee
  et construit nodes/links + drilldown, dans le MÊME contrat JSON que Paris /
  Marseille (BudgetClient consomme les trois).

  Axe = NATURE (chapitre M14/M57), jamais fonction. type_budget = 'execute'
  (balances comptables = comptes de gestion exécutés).
*/

SELECT
    code_insee,
    siren,
    commune_nom,
    population,
    dep_name,
    reg_name,
    annee,
    'execute'         AS type_budget,
    section,
    sens_flux,
    sankey_group_fr,
    sankey_group_en,
    category_fr,
    category_en,
    montant_total     AS montant
FROM {{ ref('core_budget_national') }}
WHERE montant_total > 0
