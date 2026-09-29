-- =============================================================================
-- Core: Budget Principal (OBT)
--
-- Source: stg_budget_principal + seed_mapping_thematiques
-- Description: Table dénormalisée du budget avec enrichissements thématiques
--
-- Grain: (annee, section, chapitre_code, nature_code, fonction_code, sens_flux)
-- Une ligne = une combinaison budgétaire unique
--
-- Enrichissements (ode_*):
--   - ode_thematique: thématique dashboard basée sur chapitre/fonction
--   - ode_categorie_flux: catégorie de dépense (Personnel, Subventions, etc.)
--
-- Output: ~29k lignes, années 2019-2025
-- =============================================================================

WITH budget AS (
    SELECT * FROM {{ ref('stg_budget_principal') }}
),

mapping_thematiques AS (
    SELECT * FROM {{ ref('stg_mapping_thematiques') }}
),

-- =============================================================================
-- ÉTAPE 1: Trouver LA meilleure thématique pour chaque (chapitre, fonction)
-- Priorité: match fonction_prefix spécifique > match générique (fonction_prefix NULL)
-- Logique partagée avec core_budget_vote — macros/budget_thematique_best_match.sql
-- =============================================================================
{{ budget_thematique_best_match() }},

-- =============================================================================
-- ÉTAPE 2: Enrichissement
-- =============================================================================
enriched AS (
    SELECT
        -- =====================================================================
        -- COLONNES ORIGINALES (pas de préfixe)
        -- =====================================================================
        -- City discriminator. Per ADR-0011 this stays a constant 'paris':
        -- Paris and Marseille budgets are separate, source-shaped models that
        -- share the extracted macros (NOT a physical UNION on commune_slug),
        -- so there is no cross-city union here.
        -- See docs/decisions/0011-budget-convergence.md.
        'paris' AS commune_slug,
        b.annee,
        b.section,
        b.sens_flux,
        b.type_operation,
        b.chapitre_code,
        b.chapitre_libelle,
        b.nature_code,
        b.nature_libelle,
        b.fonction_code,
        b.fonction_libelle,
        b.montant,
        b.cle_technique,
        -- 'open_data_ville' (open data de la Ville) ou 'balance_dgfip' (année
        -- pas encore publiée par la Ville, voir stg_budget_principal)
        b.source_budget,
        
        -- =====================================================================
        -- COLONNES ENRICHIES (préfixe ode_)
        -- =====================================================================
        
        -- Thématique dashboard (mapping chapitre → thématique)
        COALESCE(
            bt.mapped_thematique,
            CASE b.chapitre_code
                WHEN '930' THEN 'Administration'
                WHEN '931' THEN 'Sécurité'
                WHEN '932' THEN 'Éducation'
                WHEN '933' THEN 'Culture & Sport'
                WHEN '934' THEN 'Social'
                WHEN '935' THEN 'Urbanisme'
                WHEN '936' THEN 'Économie'
                WHEN '937' THEN 'Environnement'
                WHEN '938' THEN 'Transport'
                WHEN '939' THEN 'Action économique'
                ELSE 'Autre'
            END
        ) AS ode_thematique,
        
        -- Catégorie de flux (basée sur nature comptable) — macro partagée
        {{ ode_categorie_flux('b.nature_code') }} AS ode_categorie_flux,
        
        -- Flag disponibilité subventions pour cette année
        CASE WHEN b.annee IN (2020, 2021) THEN FALSE ELSE TRUE END AS donnees_subv_disponibles,
        
        -- Métadonnées
        CURRENT_TIMESTAMP() AS _dbt_updated_at

    FROM budget b
    LEFT JOIN best_thematique bt
        ON b.chapitre_code = bt.chapitre_code
        AND b.fonction_code = bt.fonction_code
)

SELECT * FROM enriched
