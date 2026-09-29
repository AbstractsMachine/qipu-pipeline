-- =============================================================================
-- Mart: Évolution Budget
--
-- Sources: core_budget (exécuté 2019-2025) + core_budget_vote (voté, années sans exécuté : 2026)
-- Description: Agrégations temporelles du budget pour graphiques d'évolution
--
-- Granularités disponibles:
--   - Par année + sens (recette/dépense) - totaux globaux
--   - Par année + section (Fonctionnement/Investissement) - pour épargne brute
--   - Par année + thématique macro
--
-- Métriques calculées:
--   - Épargne brute = Recettes fonct. - Dépenses fonct.
--   - Surplus/Déficit = Recettes propres (hors emprunts) - Dépenses
--   - Métriques dette:
--     - Emprunts = nature 16xx recettes (nouveaux emprunts)
--     - Remboursement principal = nature 16xx dépenses
--     - Intérêts dette = nature 66xx dépenses
--     - Variation dette nette = emprunts - remboursement_principal
--
-- ARCHITECTURE:
--   Les budgets exécutés (CA) sont la source de vérité pour 2019-2024.
--   Pour 2025-2026, seul le budget voté (BP) est disponible. On utilise
--   core_budget_vote pour ces années uniquement, afin d'éviter les doublons.
--   Le champ type_budget distingue 'execute' (CA) de 'vote' (BP).
--
-- Output: ~350 lignes (8 ans × ~40 dimensions)
-- =============================================================================

WITH budget_execute AS (
    -- Budget exécuté (Compte Administratif) — source de vérité pour 2019-2024
    SELECT
        annee,
        section,
        sens_flux,
        chapitre_code,
        chapitre_libelle,
        nature_code,
        montant,
        ode_thematique AS thematique_macro,
        'execute' AS type_budget
    FROM {{ ref('core_budget') }}
),

budget_vote AS (
    -- Budget voté (Budget Primitif) — seulement pour les années sans budget
    -- exécuté (2026 aujourd'hui ; 2025 est exécuté depuis le 28/09/2026), pour
    -- éviter les doublons avec core_budget
    SELECT
        annee,
        section,
        sens_flux,
        chapitre_code,
        chapitre_libelle,
        nature_code,
        montant,
        ode_thematique AS thematique_macro,
        'vote' AS type_budget
    FROM {{ ref('core_budget_vote') }}
    WHERE annee NOT IN (SELECT DISTINCT annee FROM {{ ref('core_budget') }})
),

budget_base AS (
    SELECT
        annee,
        section,
        sens_flux,
        chapitre_code,
        chapitre_libelle,
        nature_code,
        montant,
        thematique_macro,
        type_budget,
        -- Flags pour métriques dette
        CASE WHEN nature_code LIKE '16%' AND sens_flux = 'Recette' THEN TRUE ELSE FALSE END AS est_emprunt,
        CASE WHEN nature_code LIKE '16%' AND sens_flux = 'Dépense' THEN TRUE ELSE FALSE END AS est_remboursement_principal,
        CASE WHEN nature_code LIKE '66%' AND sens_flux = 'Dépense' THEN TRUE ELSE FALSE END AS est_interets_dette
    FROM budget_execute

    UNION ALL

    SELECT
        annee,
        section,
        sens_flux,
        chapitre_code,
        chapitre_libelle,
        nature_code,
        montant,
        thematique_macro,
        type_budget,
        CASE WHEN nature_code LIKE '16%' AND sens_flux = 'Recette' THEN TRUE ELSE FALSE END AS est_emprunt,
        CASE WHEN nature_code LIKE '16%' AND sens_flux = 'Dépense' THEN TRUE ELSE FALSE END AS est_remboursement_principal,
        CASE WHEN nature_code LIKE '66%' AND sens_flux = 'Dépense' THEN TRUE ELSE FALSE END AS est_interets_dette
    FROM budget_vote
),

-- Agrégation par année et sens (totaux globaux)
par_annee_sens AS (
    SELECT
        annee,
        sens_flux,
        -- type_budget est le même pour toute une année → MAX suffit
        MAX(type_budget) AS type_budget,
        SUM(montant) AS montant_total,
        COUNT(*) AS nb_lignes
    FROM budget_base
    GROUP BY 1, 2
),

-- Calcul des variations annuelles
avec_variation AS (
    SELECT
        annee,
        sens_flux,
        type_budget,
        montant_total,
        nb_lignes,
        LAG(montant_total) OVER (PARTITION BY sens_flux ORDER BY annee) AS montant_annee_prec,
        SAFE_DIVIDE(
            montant_total - LAG(montant_total) OVER (PARTITION BY sens_flux ORDER BY annee),
            LAG(montant_total) OVER (PARTITION BY sens_flux ORDER BY annee)
        ) * 100 AS variation_pct
    FROM par_annee_sens
),

-- Agrégation par année et section (Fonctionnement / Investissement)
par_section AS (
    SELECT
        annee,
        section,
        sens_flux,
        MAX(type_budget) AS type_budget,
        SUM(montant) AS montant_total,
        COUNT(*) AS nb_lignes
    FROM budget_base
    GROUP BY 1, 2, 3
),

-- Calcul épargne brute, surplus financier et métriques dette par année
metriques_financieres AS (
    SELECT
        annee,
        MAX(type_budget) AS type_budget,
        -- Recettes et dépenses par section
        SUM(CASE WHEN section = 'Fonctionnement' AND sens_flux = 'Recette' THEN montant ELSE 0 END) AS recettes_fonct,
        SUM(CASE WHEN section = 'Fonctionnement' AND sens_flux = 'Dépense' THEN montant ELSE 0 END) AS depenses_fonct,
        SUM(CASE WHEN section = 'Investissement' AND sens_flux = 'Recette' THEN montant ELSE 0 END) AS recettes_invest,
        SUM(CASE WHEN section = 'Investissement' AND sens_flux = 'Dépense' THEN montant ELSE 0 END) AS depenses_invest,
        -- Métriques dette
        SUM(CASE WHEN est_emprunt THEN montant ELSE 0 END) AS emprunts,
        SUM(CASE WHEN est_remboursement_principal THEN montant ELSE 0 END) AS remboursement_principal,
        SUM(CASE WHEN est_interets_dette THEN montant ELSE 0 END) AS interets_dette,
        -- Totaux
        SUM(CASE WHEN sens_flux = 'Recette' THEN montant ELSE 0 END) AS recettes_totales,
        SUM(CASE WHEN sens_flux = 'Dépense' THEN montant ELSE 0 END) AS depenses_totales
    FROM budget_base
    GROUP BY annee
),

metriques_calculees AS (
    SELECT
        annee,
        type_budget,
        recettes_fonct,
        depenses_fonct,
        recettes_invest,
        depenses_invest,
        -- Métriques dette
        emprunts,
        remboursement_principal,
        interets_dette,
        -- Variation dette nette = nouveaux emprunts - remboursement du principal
        -- Positif = la dette augmente, Négatif = la dette diminue
        emprunts - remboursement_principal AS variation_dette_nette,
        -- Totaux
        recettes_totales,
        depenses_totales,
        -- Épargne brute = surplus de fonctionnement
        recettes_fonct - depenses_fonct AS epargne_brute,
        -- Recettes propres = recettes totales - emprunts
        recettes_totales - emprunts AS recettes_propres,
        -- Surplus/Déficit financier = recettes propres - dépenses
        (recettes_totales - emprunts) - depenses_totales AS surplus_deficit,
        -- Solde comptable (pour référence)
        recettes_totales - depenses_totales AS solde_comptable
    FROM metriques_financieres
),

-- Agrégation par année et thématique macro
par_thematique AS (
    SELECT
        annee,
        sens_flux,
        thematique_macro,
        MAX(type_budget) AS type_budget,
        SUM(montant) AS montant_total,
        COUNT(*) AS nb_lignes
    FROM budget_base
    GROUP BY 1, 2, 3
),

-- Union des vues
resultats AS (
    -- Vue 1: Par sens avec variation
    SELECT
        'par_sens' AS vue,
        annee,
        type_budget,
        sens_flux,
        NULL AS section,
        NULL AS thematique_macro,
        montant_total,
        nb_lignes,
        variation_pct,
        montant_annee_prec,
        NULL AS epargne_brute,
        NULL AS recettes_propres,
        NULL AS surplus_deficit,
        NULL AS emprunts,
        NULL AS remboursement_principal,
        NULL AS interets_dette,
        NULL AS variation_dette_nette
    FROM avec_variation

    UNION ALL

    -- Vue 2: Par section
    SELECT
        'par_section' AS vue,
        annee,
        type_budget,
        sens_flux,
        section,
        NULL AS thematique_macro,
        montant_total,
        nb_lignes,
        NULL AS variation_pct,
        NULL AS montant_annee_prec,
        NULL AS epargne_brute,
        NULL AS recettes_propres,
        NULL AS surplus_deficit,
        NULL AS emprunts,
        NULL AS remboursement_principal,
        NULL AS interets_dette,
        NULL AS variation_dette_nette
    FROM par_section

    UNION ALL

    -- Vue 3: Métriques financières calculées (incluant dette)
    SELECT
        'metriques' AS vue,
        annee,
        type_budget,
        NULL AS sens_flux,
        NULL AS section,
        NULL AS thematique_macro,
        NULL AS montant_total,
        NULL AS nb_lignes,
        NULL AS variation_pct,
        NULL AS montant_annee_prec,
        epargne_brute,
        recettes_propres,
        surplus_deficit,
        emprunts,
        remboursement_principal,
        interets_dette,
        variation_dette_nette
    FROM metriques_calculees

    UNION ALL

    -- Vue 4: Par thématique macro
    SELECT
        'par_thematique' AS vue,
        annee,
        type_budget,
        sens_flux,
        NULL AS section,
        thematique_macro,
        montant_total,
        nb_lignes,
        NULL AS variation_pct,
        NULL AS montant_annee_prec,
        NULL AS epargne_brute,
        NULL AS recettes_propres,
        NULL AS surplus_deficit,
        NULL AS emprunts,
        NULL AS remboursement_principal,
        NULL AS interets_dette,
        NULL AS variation_dette_nette
    FROM par_thematique
)

SELECT
    vue,
    annee,
    type_budget,
    sens_flux,
    section,
    thematique_macro,
    montant_total,
    nb_lignes,
    ROUND(variation_pct, 2) AS variation_pct,
    montant_annee_prec,
    epargne_brute,
    recettes_propres,
    surplus_deficit,
    -- Métriques dette
    emprunts,
    remboursement_principal,
    interets_dette,
    variation_dette_nette,
    CURRENT_TIMESTAMP() AS _dbt_updated_at
FROM resultats
ORDER BY vue, annee, sens_flux, section, thematique_macro
