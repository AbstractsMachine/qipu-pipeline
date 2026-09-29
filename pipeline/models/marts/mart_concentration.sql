-- =============================================================================
-- Mart: Concentration des dépenses (Analyse Pareto)
--
-- Source: core_subventions, core_ap_projets
-- Description: Analyse de la concentration des dépenses pour insights de gouvernance
--
-- Métriques calculées:
--   - Top N bénéficiaires/projets par montant
--   - % cumulé (courbe Pareto)
--   - Seuils 80/20 et 95/5
--
-- Usage Frontend: Graphique Pareto + KPIs concentration
-- Output: ~500 lignes (top 250 par domaine × 2 domaines)
-- =============================================================================

-- =============================================================================
-- SUBVENTIONS: Concentration par bénéficiaire
-- =============================================================================
WITH subventions_par_beneficiaire AS (
    SELECT
        -- Identité de l'organisation toutes années (une graphie par exercice
        -- ne coupe plus un bénéficiaire en plusieurs rangs).
        ode_identite AS beneficiaire_normalise,
        ode_thematique,
        ode_type_organisme,
        SUM(montant) AS montant_total,
        COUNT(DISTINCT annee) AS nb_annees,
        MIN(annee) AS premiere_annee,
        MAX(annee) AS derniere_annee
    FROM {{ ref('core_subventions') }}
    WHERE ode_identite IS NOT NULL
    GROUP BY 1, 2, 3
),

subventions_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY montant_total DESC) AS rang,
        SUM(montant_total) OVER () AS total_global,
        SUM(montant_total) OVER (ORDER BY montant_total DESC) AS cumul_montant
    FROM subventions_par_beneficiaire
),

subventions_pareto AS (
    SELECT
        'subventions' AS domaine,
        rang,
        beneficiaire_normalise AS entite,
        ode_thematique AS thematique,
        ode_type_organisme AS type_organisme,
        montant_total,
        nb_annees,
        premiere_annee,
        derniere_annee,
        total_global,
        cumul_montant,
        ROUND(cumul_montant / total_global * 100, 2) AS pct_cumule,
        ROUND(montant_total / total_global * 100, 2) AS pct_part,
        -- Seuils Pareto
        CASE 
            WHEN cumul_montant / total_global <= 0.80 THEN 'top_80'
            WHEN cumul_montant / total_global <= 0.95 THEN 'top_95'
            ELSE 'reste'
        END AS segment_pareto
    FROM subventions_ranked
    WHERE rang <= 250  -- Top 250 bénéficiaires
),

-- =============================================================================
-- INVESTISSEMENTS: Concentration par mission/programme AP
-- Note: core_ap_projets n'a pas ode_thematique, on utilise mission_libelle
-- =============================================================================
ap_par_mission AS (
    SELECT
        mission_libelle AS entite,
        -- Pas de ode_thematique dans AP, on utilise mission comme proxy
        mission_libelle AS thematique,
        'public' AS type_organisme,  -- AP sont toujours publics
        SUM(montant) AS montant_total,
        COUNT(DISTINCT annee) AS nb_annees,
        MIN(annee) AS premiere_annee,
        MAX(annee) AS derniere_annee
    FROM {{ ref('core_ap_projets') }}
    WHERE mission_libelle IS NOT NULL
    GROUP BY 1
),

ap_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY montant_total DESC) AS rang,
        SUM(montant_total) OVER () AS total_global,
        SUM(montant_total) OVER (ORDER BY montant_total DESC) AS cumul_montant
    FROM ap_par_mission
),

ap_pareto AS (
    SELECT
        'investissements' AS domaine,
        rang,
        entite,
        thematique,
        type_organisme,
        montant_total,
        nb_annees,
        premiere_annee,
        derniere_annee,
        total_global,
        cumul_montant,
        ROUND(cumul_montant / total_global * 100, 2) AS pct_cumule,
        ROUND(montant_total / total_global * 100, 2) AS pct_part,
        CASE 
            WHEN cumul_montant / total_global <= 0.80 THEN 'top_80'
            WHEN cumul_montant / total_global <= 0.95 THEN 'top_95'
            ELSE 'reste'
        END AS segment_pareto
    FROM ap_ranked
    WHERE rang <= 250
)

-- =============================================================================
-- RÉSULTAT FINAL: Union des deux domaines
-- =============================================================================
SELECT
    domaine,
    rang,
    entite,
    thematique,
    type_organisme,
    montant_total,
    nb_annees,
    premiere_annee,
    derniere_annee,
    total_global,
    cumul_montant,
    pct_cumule,
    pct_part,
    segment_pareto,
    CURRENT_TIMESTAMP() AS _dbt_updated_at
FROM subventions_pareto

UNION ALL

SELECT
    domaine,
    rang,
    entite,
    thematique,
    type_organisme,
    montant_total,
    nb_annees,
    premiere_annee,
    derniere_annee,
    total_global,
    cumul_montant,
    pct_cumule,
    pct_part,
    segment_pareto,
    CURRENT_TIMESTAMP() AS _dbt_updated_at
FROM ap_pareto

ORDER BY domaine, rang
