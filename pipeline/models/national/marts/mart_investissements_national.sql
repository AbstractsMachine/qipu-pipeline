{{
  config(
    enabled=true,
    materialized='table',
    tags=['national', 'marts']
  )
}}

/*
  Mart: investissements national (source d'export, row-level)

  Le volet INVESTISSEMENT du budget par nature (comptes classe 1 & 2) : dépenses
  d'équipement (immobilisations 20/21/23) et leur financement (subventions
  d'investissement, dotations/FCTVA, emprunts). Déterministe, sans enrichissement.
  L'exporteur agrège par commune (total, financement vs équipement, par groupe,
  par année).
*/

SELECT
    code_insee,
    commune_nom,
    population,
    annee,
    sens_flux,
    sankey_group_fr,
    category_fr,
    montant_total AS montant
FROM {{ ref('core_budget_national') }}
WHERE section = 'Investissement'
  AND montant_total > 0
