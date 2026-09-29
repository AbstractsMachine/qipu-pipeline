-- =============================================================================
-- Mart: section d'investissement exécutée, par année × chapitre
--
-- Consommé par: pipeline/scripts/export/export_investissement_tendances.py
--   → website/public/data/investissement_tendances.json (page Investissements :
--     le chiffre « investi hors dette », les barres par chapitre, les fiches
--     chapitre et arrondissement).
--
-- Source: core_budget (exécuté seulement : open data de la Ville, ou balance
-- DGFiP pour une année qu'elle n'a pas encore publiée). Le fichier était écrit
-- à la main jusqu'en 2024 ; ce mart le rend reproductible (vérifié : 2019-2024
-- identiques au fichier commité).
--
-- Grain: annee × chapitre_code
-- =============================================================================

{{ config(materialized='table', schema='marts', tags=['mart','budget','investissements']) }}

SELECT
    annee,
    chapitre_code,
    ANY_VALUE(chapitre_libelle) AS chapitre_libelle,
    SUM(IF(sens_flux = 'Dépense', montant, 0)) AS depenses,
    SUM(IF(sens_flux = 'Recette', montant, 0)) AS recettes,
    ANY_VALUE(source_budget) AS source_budget
FROM {{ ref('core_budget') }}
WHERE section = 'Investissement'
GROUP BY annee, chapitre_code
