-- =============================================================================
-- Mart: lignes budgétaires pour la construction du Sankey
--
-- Consommé par: pipeline/scripts/export/export_sankey_data.py
--   → website/public/data/budget_sankey_{year}.json
--
-- Sources:
--   - core_budget        → type_budget = 'execute' (CA, 2019-2025 ; source_budget dit d'où vient l'année)
--   - core_budget_vote   → type_budget = 'vote'    (BP, 2020-2026)
--
-- Grain: ligne budgétaire (chapitre × nature × fonction × sens × annee × type_budget)
-- Filtres: montant > 0 (exclu les lignes nulles, qui n'apportent rien au Sankey).
--
-- L'export sélectionne par (annee, type_budget) selon que l'année est exécutée
-- ou seulement votée — voir VOTED_YEARS dans le script Python.
-- =============================================================================

{{ config(materialized='table', schema='marts', tags=['mart','budget','sankey']) }}

WITH executed AS (
    SELECT
        annee,
        'execute' AS type_budget,
        sens_flux,
        chapitre_code,
        chapitre_libelle,
        fonction_libelle,
        nature_libelle,
        ode_categorie_flux,
        montant,
        source_budget
    FROM {{ ref('core_budget') }}
    WHERE montant > 0
),

voted AS (
    SELECT
        annee,
        'vote' AS type_budget,
        sens_flux,
        chapitre_code,
        chapitre_libelle,
        fonction_libelle,
        nature_libelle,
        ode_categorie_flux,
        montant,
        'budget_primitif' AS source_budget
    FROM {{ ref('core_budget_vote') }}
    WHERE montant > 0
)

SELECT * FROM executed
UNION ALL
SELECT * FROM voted
