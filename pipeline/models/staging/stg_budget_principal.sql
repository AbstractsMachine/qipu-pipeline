-- =============================================================================
-- Staging: Budget Principal (Compte Administratif)
--
-- Sources:
--   1. comptes_administratifs_budgets_principaux_a_partir_de_2019_m57_ville_departement
--      (open data de la Ville) — SOURCE DE VÉRITÉ pour chaque année qu'elle publie.
--   2. Pour une année exécutée que la Ville n'a pas (encore) mise en open data :
--      la balance DGFiP « présentation croisée nature-fonction »
--      (national_raw.dgfip_balances_nature_fonction), budget principal de la
--      Ville de Paris (SIREN 217500016, CBUDG 1), ramenée au grain de l'open data.
--      Une année publiée par la Ville n'est JAMAIS lue dans la DGFiP.
--
-- Pourquoi la DGFiP est sûre (mesuré le 28/09/2026) :
--   - 2024, présent dans les deux sources : 4 227 cellules
--     (section × sens × fonction × nature) identiques au centime, 0 écart ;
--     les seules différences viennent de l'open data (lignes « #VALEURMULTI »
--     sans nature, comptes 4581x/4582x subdivisés par mandat) et laissent les
--     totaux par section et par sens égaux ;
--   - 2025 : chaque chapitre retombe au centime sur le compte administratif
--     imprimé (seed_paris_ca_totaux_imprimes, test balance_budget_vs_ca_imprime).
--
-- Passage DGFiP → grain open data :
--   - réel = opérations budgétaires nettes − opérations d'ordre budgétaires ;
--     dépense = débit, recette = crédit ; section = classe du compte (6/7 →
--     fonctionnement, sinon investissement) ;
--   - FONCTION DGFiP = préfixe de section (90 / 93) + sous-fonction, ou le code
--     du chapitre non ventilé (921-923, 940-944) → fonction « 01 » ;
--   - chapitre = préfixe + 1er chiffre de la sous-fonction, sauf 05x → x05,
--     43x/44x → x43/x44 (APA, RSA) : la règle reproduit tous les couples
--     (fonction, chapitre) publiés par la Ville 2019-2024 ;
--   - nature : le compte DGFiP est parfois plus fin (615221) que la nature
--     publiée par la Ville (61522) → plus long préfixe parmi les natures déjà
--     publiées ; un compte jamais publié garde son code ;
--   - libellés : le dernier libellé publié par la Ville pour ce code, sinon
--     seed_paris_ca_libelles (recopié du compte administratif, page citée).
--
-- source_budget : 'open_data_ville' ou 'balance_dgfip' — l'export écrit la
-- source de chaque année dans son JSON (lien « source » du site).
--
-- Transformations communes:
--   - Filtre: opérations réelles uniquement
--   - Filtre: montant > 0
--   - Typage: FLOAT64 pour montants
--   - Agrégation: SUM(montant) par clé budgétaire
--
-- Output: ~29k lignes, années 2019-2025
-- =============================================================================

WITH source AS (
    SELECT *
    FROM {{ source('paris_raw', 'comptes_administratifs_budgets_principaux_a_partir_de_2019_m57_ville_departement') }}
),

cleaned AS (
    SELECT
        -- =====================================================================
        -- IDENTIFIANTS
        -- =====================================================================
        SAFE_CAST(exercice_comptable AS INT64) AS annee,
        
        -- Section budgétaire
        CASE section_budgetaire_i_f
            WHEN 'I' THEN 'Investissement'
            WHEN 'F' THEN 'Fonctionnement'
            ELSE section_budgetaire_i_f
        END AS section,
        
        -- Sens du flux
        CASE 
            WHEN UPPER(sens_depense_recette) LIKE '%DÉPENSE%' OR UPPER(sens_depense_recette) LIKE '%DEPENSE%' THEN 'Dépense'
            WHEN UPPER(sens_depense_recette) LIKE '%RECETTE%' THEN 'Recette'
            ELSE sens_depense_recette
        END AS sens_flux,
        
        -- Type d'opération
        type_d_operation_r_o_i_m AS type_operation,
        
        -- =====================================================================
        -- CODES BUDGÉTAIRES (clés de jointure)
        -- =====================================================================
        SAFE_CAST(chapitre_budgetaire_cle AS STRING) AS chapitre_code,
        chapitre_niveau_vote_texte_descriptif AS chapitre_libelle,
        
        SAFE_CAST(nature_budgetaire_cle AS STRING) AS nature_code,
        nature_budgetaire_texte AS nature_libelle,
        
        SAFE_CAST(fonction_cle AS STRING) AS fonction_code,
        fonction_texte AS fonction_libelle,
        
        -- =====================================================================
        -- MONTANTS
        -- =====================================================================
        ABS(SAFE_CAST(mandate_titre_apres_regul AS FLOAT64)) AS montant,
        
        -- =====================================================================
        -- CLÉ TECHNIQUE (inclut nature_libelle pour unicité)
        -- Certaines lignes ont même code mais libellé différent (ex: FNGIR vs Péréquation)
        -- =====================================================================
        CONCAT(
            SAFE_CAST(exercice_comptable AS STRING), '-',
            COALESCE(section_budgetaire_i_f, 'X'), '-',
            CASE WHEN UPPER(sens_depense_recette) LIKE '%DÉPENSE%' THEN 'D' ELSE 'R' END, '-',
            COALESCE(SAFE_CAST(chapitre_budgetaire_cle AS STRING), '000'), '-',
            COALESCE(SAFE_CAST(nature_budgetaire_cle AS STRING), '000'), '-',
            COALESCE(SAFE_CAST(fonction_cle AS STRING), '000'), '-',
            -- Hash du libellé pour différencier lignes avec même code
            SUBSTR(TO_HEX(MD5(COALESCE(nature_budgetaire_texte, ''))), 1, 8)
        ) AS cle_technique
        
    FROM source
    WHERE 
        -- Filtre opérations réelles uniquement
        (type_d_operation_r_o_i_m = 'Réel' OR type_d_operation_r_o_i_m = 'R')
        -- Filtre montants positifs
        AND SAFE_CAST(mandate_titre_apres_regul AS FLOAT64) > 0
),

-- =============================================================================
-- AGRÉGATION: la source contient des sous-lignes de mandats au même grain
-- budgétaire (même année/section/flux/chapitre/nature/fonction/libellé)
-- sans identifiant distinct. On les agrège en sommant les montants.
-- =============================================================================
aggregated AS (
    SELECT
        annee,
        section,
        sens_flux,
        type_operation,
        chapitre_code,
        chapitre_libelle,
        nature_code,
        nature_libelle,
        fonction_code,
        fonction_libelle,
        SUM(montant) AS montant,
        cle_technique,
        'open_data_ville' AS source_budget
    FROM cleaned
    GROUP BY
        annee, section, sens_flux, type_operation,
        chapitre_code, chapitre_libelle,
        nature_code, nature_libelle,
        fonction_code, fonction_libelle,
        cle_technique
),

-- =============================================================================
-- Années exécutées absentes de l'open data : balance DGFiP
-- =============================================================================
ods_years AS (
    SELECT DISTINCT SAFE_CAST(exercice_comptable AS INT64) AS annee FROM source
),

ods_labels AS (
    SELECT
        SAFE_CAST(exercice_comptable AS INT64) AS annee,
        SAFE_CAST(chapitre_budgetaire_cle AS STRING) AS chapitre_code,
        chapitre_niveau_vote_texte_descriptif AS chapitre_libelle,
        SAFE_CAST(nature_budgetaire_cle AS STRING) AS nature_code,
        nature_budgetaire_texte AS nature_libelle,
        SAFE_CAST(fonction_cle AS STRING) AS fonction_code,
        fonction_texte AS fonction_libelle
    FROM source
    WHERE nature_budgetaire_cle NOT LIKE '#%'
),

ods_natures AS (
    SELECT DISTINCT nature_code FROM ods_labels WHERE nature_code IS NOT NULL
),

lib_chapitre AS (
    SELECT chapitre_code, chapitre_libelle FROM ods_labels
    WHERE chapitre_libelle IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY chapitre_code ORDER BY annee DESC, chapitre_libelle) = 1
),

lib_nature AS (
    SELECT nature_code, nature_libelle FROM ods_labels
    WHERE nature_libelle IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY nature_code ORDER BY annee DESC, nature_libelle) = 1
),

lib_fonction AS (
    SELECT fonction_code, fonction_libelle FROM ods_labels
    WHERE fonction_libelle IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY fonction_code ORDER BY annee DESC, fonction_libelle) = 1
),

lib_ca AS (
    SELECT axe, code, libelle FROM {{ ref('seed_paris_ca_libelles') }}
),

dgfip AS (
    SELECT
        annee,
        fonction,
        compte,
        COALESCE(SAFE_CAST(REPLACE(obnetdeb, ',', '.') AS NUMERIC), 0)
          - COALESCE(SAFE_CAST(REPLACE(oobdeb, ',', '.') AS NUMERIC), 0) AS depense,
        COALESCE(SAFE_CAST(REPLACE(obnetcre, ',', '.') AS NUMERIC), 0)
          - COALESCE(SAFE_CAST(REPLACE(oobcre, ',', '.') AS NUMERIC), 0) AS recette
    FROM {{ source('national_raw', 'dgfip_balances_nature_fonction') }}
    WHERE categ = 'PARIS'          -- la table est groupée par categ, cbudg
      AND cbudg = '1'
      AND siren = '217500016'
      AND fonction IS NOT NULL
      AND annee >= 2019
      AND annee NOT IN (SELECT annee FROM ods_years WHERE annee IS NOT NULL)
),

dgfip_flux AS (
    SELECT annee, fonction, compte, 'Dépense' AS sens_flux, depense AS montant FROM dgfip WHERE depense <> 0
    UNION ALL
    SELECT annee, fonction, compte, 'Recette' AS sens_flux, recette AS montant FROM dgfip WHERE recette <> 0
),

dgfip_codes AS (
    SELECT
        f.annee,
        f.sens_flux,
        {{ paris_dgfip_section('f.compte') }} AS section,
        IF(LEFT(f.compte, 1) IN ('6', '7'), 'F', 'I') AS section_code,
        {{ paris_dgfip_chapitre('f.fonction') }} AS chapitre_code,
        {{ paris_dgfip_fonction('f.fonction') }} AS fonction_code,
        COALESCE(n.nature_code, f.compte) AS nature_code,
        f.montant
    FROM dgfip_flux f
    LEFT JOIN ods_natures n
        ON STARTS_WITH(f.compte, n.nature_code)
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY f.annee, f.fonction, f.compte, f.sens_flux
        ORDER BY LENGTH(n.nature_code) DESC
    ) = 1
),

dgfip_labelled AS (
    SELECT
        d.annee,
        d.section,
        d.sens_flux,
        'Réel' AS type_operation,
        d.chapitre_code,
        lc.chapitre_libelle,
        d.nature_code,
        COALESCE(ln.nature_libelle, can.libelle) AS nature_libelle,
        d.fonction_code,
        COALESCE(lf.fonction_libelle, caf.libelle) AS fonction_libelle,
        d.section_code,
        d.montant AS montant_net
    FROM dgfip_codes d
    LEFT JOIN lib_chapitre lc ON lc.chapitre_code = d.chapitre_code
    LEFT JOIN lib_nature ln ON ln.nature_code = d.nature_code
    LEFT JOIN lib_ca can ON can.axe = 'nature' AND can.code = d.nature_code
    LEFT JOIN lib_fonction lf ON lf.fonction_code = d.fonction_code
    LEFT JOIN lib_ca caf ON caf.axe = 'fonction' AND caf.code = d.fonction_code
),

dgfip_aggregated AS (
    SELECT
        annee,
        section,
        sens_flux,
        type_operation,
        chapitre_code,
        chapitre_libelle,
        nature_code,
        nature_libelle,
        fonction_code,
        fonction_libelle,
        CAST(SUM(montant_net) AS FLOAT64) AS montant,
        CONCAT(
            CAST(annee AS STRING), '-',
            section_code, '-',
            IF(sens_flux = 'Dépense', 'D', 'R'), '-',
            COALESCE(chapitre_code, '000'), '-',
            COALESCE(nature_code, '000'), '-',
            COALESCE(fonction_code, '000'), '-',
            SUBSTR(TO_HEX(MD5(COALESCE(nature_libelle, ''))), 1, 8)
        ) AS cle_technique,
        'balance_dgfip' AS source_budget
    FROM dgfip_labelled
    GROUP BY
        annee, section, sens_flux, type_operation,
        chapitre_code, chapitre_libelle,
        nature_code, nature_libelle,
        fonction_code, fonction_libelle,
        section_code
    -- même règle que l'open data : une cellule nette négative (annulations
    -- supérieures aux émissions) n'est pas gardée
    HAVING SUM(montant_net) > 0
)

SELECT * FROM aggregated
UNION ALL
SELECT * FROM dgfip_aggregated
