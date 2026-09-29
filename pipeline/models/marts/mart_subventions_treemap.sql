-- =============================================================================
-- MART: Subventions Treemap
-- 
-- Vue optimisée pour le treemap et la table des subventions.
-- PAS DE GÉOLOCALISATION : les subventions vont à des organisations, pas des lieux.
--
-- Grain: (annee, ode_thematique) pour agrégation treemap
-- =============================================================================

WITH subventions AS (
    SELECT *
    FROM {{ ref('core_subventions') }}
    WHERE donnees_disponibles = TRUE
      AND montant > 0
),

-- Agrégation par thématique pour treemap
par_thematique AS (
    SELECT
        annee,
        ode_thematique AS thematique,
        -- Une organisation publiée sous plusieurs graphies compte une fois
        -- (ode_identite, cf. dim_beneficiaire).
        COUNT(DISTINCT ode_identite) AS nb_beneficiaires,
        COUNT(*) AS nb_subventions,
        SUM(montant) AS montant_total
    FROM subventions
    GROUP BY annee, ode_thematique
),

-- Top bénéficiaires par thématique (pour drill-down)
top_beneficiaires AS (
    SELECT
        annee,
        ode_thematique AS thematique,
        beneficiaire,
        beneficiaire_normalise,
        nature_juridique,
        direction,
        secteurs_activite,
        SUM(montant) AS montant_total,
        ROW_NUMBER() OVER (
            PARTITION BY annee, ode_thematique 
            ORDER BY SUM(montant) DESC
        ) AS rang
    FROM subventions
    GROUP BY 1, 2, 3, 4, 5, 6, 7
),

-- Total annuel pour pourcentages
totaux AS (
    SELECT annee, SUM(montant_total) AS total_annuel
    FROM par_thematique
    GROUP BY annee
)

SELECT
    p.annee,
    p.thematique,
    p.nb_beneficiaires,
    p.nb_subventions,
    p.montant_total,
    ROUND(100 * p.montant_total / t.total_annuel, 2) AS pct_total,
    CURRENT_TIMESTAMP() AS _dbt_updated_at
FROM par_thematique p
LEFT JOIN totaux t ON p.annee = t.annee
ORDER BY p.annee DESC, p.montant_total DESC
