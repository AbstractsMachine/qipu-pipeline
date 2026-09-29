-- =============================================================================
-- Mart: recettes budget par (année × chapitre_code)
--
-- Consommé par: pipeline/scripts/export/export_evolution_data.py
--   → website/public/data/evolution_budget.json (variation 6 ans, recettes par source)
--
-- Sources:
--   - core_budget        (exécuté, 2019-2025)
--   - core_budget_vote   (voté, seulement les années sans exécuté — 2026)
--
-- Grain: annee × chapitre_code (recettes seulement)
-- La classification chapitre → source de recette (Impôts, Emprunts, Dotations…)
-- est faite côté export Python car elle relève d'une nomenclature éditoriale
-- (REVENUE_CHAPTER_MAP) — pas du contenu source.
-- =============================================================================

{{ config(materialized='table', schema='marts', tags=['mart','budget']) }}

WITH executed AS (
    SELECT annee, chapitre_code, montant
    FROM {{ ref('core_budget') }}
    WHERE sens_flux = 'Recette'
),

voted_future AS (
    SELECT annee, chapitre_code, montant
    FROM {{ ref('core_budget_vote') }}
    WHERE sens_flux = 'Recette'
      -- exclut les années où l'exécuté est disponible (anti-doublon)
      AND annee NOT IN (SELECT DISTINCT annee FROM {{ ref('core_budget') }})
),

unioned AS (
    SELECT * FROM executed
    UNION ALL
    SELECT * FROM voted_future
)

SELECT
    annee,
    chapitre_code,
    SUM(montant) AS montant
FROM unioned
GROUP BY annee, chapitre_code
ORDER BY annee, chapitre_code
