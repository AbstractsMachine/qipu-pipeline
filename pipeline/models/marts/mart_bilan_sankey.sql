-- =============================================================================
-- Mart: Bilan Sankey (État Patrimonial)
--
-- Source: core_bilan_comptable
-- Description: Agrégation pour visualisation Sankey du bilan comptable
--
-- Structure Sankey:
--   Actif (gauche) → Patrimoine Paris (centre) ← Passif (droite)
--
-- Utilisé par: export_bilan_data.py → bilan_sankey_{year}.json
-- =============================================================================

WITH bilan AS (
    SELECT *
    FROM {{ ref('core_bilan_comptable') }}
    -- != 0 et non > 0 : les lignes négatives du passif (résultat déficitaire,
    -- report à nouveau débiteur) entrent dans les totaux par poste, sinon
    -- actif ≠ passif. Le détail (drill-down) ne garde que les lignes > 0.
    WHERE montant_net != 0
),

-- =============================================================================
-- AGRÉGATION PAR POSTE (niveau 1 du Sankey)
-- =============================================================================
postes_aggreges AS (
    SELECT
        annee,
        type_bilan,
        poste,
        SUM(montant_net) AS montant_net,
        SUM(montant_brut) AS montant_brut,
        SUM(montant_amortissements) AS montant_amortissements,
        COUNT(*) AS nb_lignes
    FROM bilan
    GROUP BY annee, type_bilan, poste
),

-- =============================================================================
-- TOTAUX PAR TYPE (Actif / Passif) pour vérification équilibre
-- =============================================================================
totaux_par_type AS (
    SELECT
        annee,
        type_bilan,
        SUM(montant_net) AS total_net
    FROM postes_aggreges
    GROUP BY annee, type_bilan
),

-- =============================================================================
-- DRILL-DOWN: détails par poste
-- =============================================================================
details_par_poste AS (
    SELECT
        annee,
        type_bilan,
        poste,
        detail,
        SUM(montant_net) AS montant_net,
        SUM(montant_brut) AS montant_brut,
        SUM(montant_amortissements) AS montant_amortissements
    FROM bilan
    WHERE detail IS NOT NULL AND TRIM(detail) != '' AND montant_net > 0
    GROUP BY annee, type_bilan, poste, detail
),

-- =============================================================================
-- CONSTRUCTION DES NODES
-- =============================================================================
nodes AS (
    -- Postes Actif (gauche)
    SELECT DISTINCT
        annee,
        poste AS name,
        'actif' AS category,
        0 AS depth
    FROM postes_aggreges
    WHERE type_bilan = 'Actif'
    
    UNION ALL
    
    -- Noeud central: Patrimoine Paris
    SELECT DISTINCT
        annee,
        'Patrimoine Paris' AS name,
        'central' AS category,
        1 AS depth
    FROM postes_aggreges
    
    UNION ALL
    
    -- Postes Passif (droite)
    SELECT DISTINCT
        annee,
        poste AS name,
        'passif' AS category,
        2 AS depth
    FROM postes_aggreges
    WHERE type_bilan = 'Passif'
),

-- =============================================================================
-- CONSTRUCTION DES LINKS
-- =============================================================================
links AS (
    -- Actif → Patrimoine Paris
    SELECT
        annee,
        poste AS source,
        'Patrimoine Paris' AS target,
        montant_net AS value,
        type_bilan
    FROM postes_aggreges
    WHERE type_bilan = 'Actif'
    
    UNION ALL
    
    -- Patrimoine Paris → Passif
    SELECT
        annee,
        'Patrimoine Paris' AS source,
        poste AS target,
        montant_net AS value,
        type_bilan
    FROM postes_aggreges
    WHERE type_bilan = 'Passif'
),

-- =============================================================================
-- CALCUL DES KPIs
-- =============================================================================
kpis AS (
    SELECT
        annee,
        
        -- Totaux
        SUM(CASE WHEN type_bilan = 'Actif' THEN total_net ELSE 0 END) AS total_actif_net,
        SUM(CASE WHEN type_bilan = 'Passif' THEN total_net ELSE 0 END) AS total_passif_net,
        
        -- Vérification équilibre (doit être proche de 0)
        ABS(
            SUM(CASE WHEN type_bilan = 'Actif' THEN total_net ELSE 0 END) -
            SUM(CASE WHEN type_bilan = 'Passif' THEN total_net ELSE 0 END)
        ) AS ecart_equilibre
        
    FROM totaux_par_type
    GROUP BY annee
),

-- =============================================================================
-- EXTRACTION DES COMPOSANTES PASSIF POUR KPIs
-- =============================================================================
passif_detail AS (
    SELECT
        annee,
        SUM(CASE WHEN poste = 'Fonds propres' THEN montant_net ELSE 0 END) AS fonds_propres,
        SUM(CASE WHEN poste = 'Dettes financières' THEN montant_net ELSE 0 END) AS dettes_financieres,
        SUM(CASE WHEN poste = 'Dettes non financières' THEN montant_net ELSE 0 END) AS dettes_non_financieres,
        SUM(CASE WHEN poste LIKE 'Provisions%' THEN montant_net ELSE 0 END) AS provisions,
        SUM(CASE WHEN poste IN ('Dettes financières', 'Dettes non financières') THEN montant_net ELSE 0 END) AS dette_totale
    FROM postes_aggreges
    WHERE type_bilan = 'Passif'
    GROUP BY annee
)

-- =============================================================================
-- OUTPUT FINAL: Structure pour export JSON
-- =============================================================================
SELECT
    'summary' AS vue,
    k.annee,
    k.total_actif_net,
    k.total_passif_net,
    k.ecart_equilibre,
    p.fonds_propres,
    p.dette_totale,
    p.dettes_financieres,
    p.dettes_non_financieres,
    p.provisions,
    -- Ratio d'endettement: Dette / Fonds propres
    SAFE_DIVIDE(p.dette_totale, p.fonds_propres) AS ratio_endettement,
    -- Part dette financière dans le passif
    SAFE_DIVIDE(p.dettes_financieres, k.total_passif_net) * 100 AS pct_dette_financiere,
    -- Part fonds propres dans le passif
    SAFE_DIVIDE(p.fonds_propres, k.total_passif_net) * 100 AS pct_fonds_propres
FROM kpis k
LEFT JOIN passif_detail p ON k.annee = p.annee
ORDER BY k.annee DESC
