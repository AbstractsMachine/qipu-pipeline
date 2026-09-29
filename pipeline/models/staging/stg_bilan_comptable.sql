-- =============================================================================
-- Staging: Bilan Comptable (État Patrimonial)
--
-- Source: bilan_comptable (open data) ; seed_paris_bilan_pdf pour un exercice
--         pas encore publié (2025, annexe aux états financiers)
-- Description: Bilan annuel de la Ville de Paris - Actif/Passif
--
-- Transformations:
--   - Nettoyage: standardisation de la casse et orthographe
--   - Normalisation: type_bilan (Actif/Passif)
--   - Typage: FLOAT64 pour montants, INT64 pour année
--   - Agrégation des doublons par clé technique
--   - NULL → 0: valeurs manquantes converties en 0 (logique comptable)
--
-- Output: ~300 lignes (après nettoyage), années 2016, 2018-2025 (2017 : passif absent à la source)
-- =============================================================================

WITH ods AS (
    SELECT
        CAST(exercice_comptable AS STRING) AS exercice_comptable,
        actif_passif, poste, detail,
        CAST(brut AS FLOAT64) AS brut,
        CAST(amortissements_et_provisions AS FLOAT64) AS amortissements_et_provisions,
        CAST(net AS FLOAT64) AS net
    FROM {{ source('paris_raw', 'bilan_comptable') }}
),

-- Un exercice que la Ville n'a pas encore mis en open data : bilan relevé dans
-- l'annexe aux états financiers (PDF), mêmes postes et libellés que l'open
-- data. Contrôle : scripts/audit/check_paris_bilan_pdf.py (totaux imprimés,
-- colonne N-1 = open data au centime). Jamais lu pour une année publiée.
pdf AS (
    SELECT
        CAST(exercice_comptable AS STRING) AS exercice_comptable,
        actif_passif, poste, detail,
        CAST(brut AS FLOAT64) AS brut,
        CAST(amortissements_et_provisions AS FLOAT64) AS amortissements_et_provisions,
        CAST(net AS FLOAT64) AS net
    FROM {{ ref('seed_paris_bilan_pdf') }}
    WHERE CAST(exercice_comptable AS STRING) NOT IN (SELECT DISTINCT exercice_comptable FROM ods)
),

source AS (
    SELECT * FROM ods
    UNION ALL
    SELECT * FROM pdf
),

-- =============================================================================
-- ÉTAPE 1: Nettoyage et typage de base
-- =============================================================================
cleaned AS (
    SELECT
        -- =====================================================================
        -- IDENTIFIANTS
        -- Note: Les noms de colonnes sont déjà nettoyés lors de l'upload
        -- (sans accents, snake_case)
        -- =====================================================================
        SAFE_CAST(exercice_comptable AS INT64) AS annee,
        
        -- Type de bilan normalisé
        CASE 
            WHEN UPPER(TRIM(actif_passif)) = 'ACTIF' THEN 'Actif'
            WHEN UPPER(TRIM(actif_passif)) = 'PASSIF' THEN 'Passif'
            ELSE INITCAP(TRIM(actif_passif))
        END AS type_bilan,
        
        -- =====================================================================
        -- POSTE: Normalisation de la casse et terminologie
        -- =====================================================================
        CASE UPPER(TRIM(poste))
            -- ACTIF
            WHEN 'ACTIF IMMOBILISE' THEN 'Actif immobilisé'
            WHEN 'ACTIF CIRCULANT' THEN 'Actif circulant'
            WHEN 'TRESORERIE' THEN 'Trésorerie'
            WHEN 'COMPTES DE REGULARISATION' THEN 'Comptes de régularisation'
            WHEN 'ECARTS DE CONVERSION ACTIF' THEN 'Écarts de conversion actif'
            -- PASSIF
            WHEN 'FONDS PROPRES' THEN 'Fonds propres'
            WHEN 'DETTES FINANCIERES' THEN 'Dettes financières'
            WHEN 'DETTES NON FINANCIERES' THEN 'Dettes non financières'
            WHEN 'PROVISIONS POUR RISQUES ET CHARGES' THEN 'Provisions pour risques et charges'
            WHEN 'PROVISIONS POUR RISQUE ET CHARGES' THEN 'Provisions pour risques et charges'
            WHEN 'ECARTS DE CONVERSION PASSIF' THEN 'Écarts de conversion passif'
            WHEN 'DETTES' THEN 'Dettes'  -- Ancienne terminologie (avant 2019)
            -- Default: normalisation casse
            ELSE INITCAP(LOWER(TRIM(poste)))
        END AS poste_normalise,
        
        -- =====================================================================
        -- DÉTAIL: Normalisation orthographique
        -- =====================================================================
        -- Correction des variations orthographiques connues
        REGEXP_REPLACE(
            REGEXP_REPLACE(
                TRIM(detail),
                r'régularisations', 'régularisation'  -- Uniformiser singulier
            ),
            r'immobilisation incorporelles', 'immobilisations incorporelles'  -- Correction faute
        ) AS detail,
        
        -- =====================================================================
        -- MONTANTS (NULL → 0)
        -- En comptabilité, une valeur absente = 0, pas "inconnu"
        -- Actif : valeurs absolues (brut, amortissements, net sont publiés
        -- positifs). Passif : le signe publié est gardé. Un résultat
        -- déficitaire ou un report à nouveau débiteur est une ligne NÉGATIVE
        -- des fonds propres (2016, 2020, 2021, 2024 open data ; 2025 annexe) ;
        -- la compter positive gonflait les fonds propres et cassait
        -- actif = passif d'exactement deux fois ce montant.
        -- =====================================================================
        CASE
            WHEN UPPER(TRIM(actif_passif)) = 'PASSIF'
                THEN COALESCE(SAFE_CAST(brut AS FLOAT64), 0)
            ELSE COALESCE(ABS(SAFE_CAST(brut AS FLOAT64)), 0)
        END AS montant_brut,
        COALESCE(ABS(SAFE_CAST(amortissements_et_provisions AS FLOAT64)), 0) AS montant_amortissements,
        -- Le net du passif : sur l'exercice 2018 la Ville a laissé la colonne
        -- `net` vide côté passif et n'a rempli que `brut` (20 lignes sur 27).
        -- Au passif il n'y a pas d'amortissement, donc brut = net : le repli est
        -- comptablement exact, et il rend l'exercice utilisable. Vérifié
        -- 2026-09-10 : passif brut 2018 = 30,26 Md€ = actif net 2018.
        CASE
            WHEN UPPER(TRIM(actif_passif)) = 'PASSIF'
                THEN COALESCE(SAFE_CAST(net AS FLOAT64),
                              SAFE_CAST(brut AS FLOAT64), 0)
            ELSE COALESCE(ABS(SAFE_CAST(net AS FLOAT64)), 0)
        END AS montant_net
        
    FROM source
    WHERE 
        -- Exclure uniquement les lignes d'en-tête ou invalides
        SAFE_CAST(exercice_comptable AS INT64) IS NOT NULL
        -- Le plancher était à 2019, au motif que les données M57 y seraient
        -- « fiables ». Vérifié exercice par exercice le 2026-09-10 : 2016 et
        -- 2018 équilibrent actif et passif au centime et sont donc publiables ;
        -- leur nomenclature est seulement plus grossière (3 postes d'actif et
        -- 4 de passif, contre 5 et 7 depuis 2019), ce qui est moins détaillé,
        -- pas faux.
        AND SAFE_CAST(exercice_comptable AS INT64) >= 2016
        -- 2017 reste dehors, et ce n'est pas notre choix : la Ville a publié
        -- un actif sans aucun passif cette année-là (28 lignes de passif, zéro
        -- valeur dans `brut` comme dans `net`). Un bilan sans passif n'est pas
        -- un bilan. À réintégrer si la Ville complète la source.
        AND SAFE_CAST(exercice_comptable AS INT64) != 2017
),

-- =============================================================================
-- ÉTAPE 2: Agrégation des doublons
-- Certaines lignes ont le même (année, type, poste, détail) mais des montants différents
-- On les agrège pour éviter les doublons
-- =============================================================================
aggregated AS (
    SELECT
        annee,
        type_bilan,
        poste_normalise AS poste,
        detail,
        SUM(montant_brut) AS montant_brut,
        SUM(montant_amortissements) AS montant_amortissements,
        SUM(montant_net) AS montant_net,
        COUNT(*) AS nb_lignes_source  -- Pour traçabilité
    FROM cleaned
    GROUP BY annee, type_bilan, poste_normalise, detail
),

-- =============================================================================
-- ÉTAPE 3: Ajout de la clé technique et métadonnées
-- =============================================================================
final AS (
    SELECT
        annee,
        type_bilan,
        poste,
        detail,
        montant_brut,
        montant_amortissements,
        montant_net,
        nb_lignes_source,
        
        -- =====================================================================
        -- CLÉ TECHNIQUE
        -- =====================================================================
        CONCAT(
            SAFE_CAST(annee AS STRING), '-',
            CASE type_bilan WHEN 'Actif' THEN 'A' ELSE 'P' END, '-',
            COALESCE(SUBSTR(TO_HEX(MD5(poste)), 1, 4), '0000'), '-',
            COALESCE(SUBSTR(TO_HEX(MD5(COALESCE(detail, ''))), 1, 8), '00000000')
        ) AS cle_technique,
        
        -- =====================================================================
        -- CLASSIFICATION ANALYTIQUE
        -- Pour faciliter les agrégations de haut niveau
        -- =====================================================================
        CASE
            -- Immobilisations
            WHEN poste = 'Actif immobilisé' AND (
                LOWER(detail) LIKE '%incorpor%' 
                OR LOWER(detail) LIKE '%subvention%'
            ) THEN 'Immobilisations incorporelles'
            
            WHEN poste = 'Actif immobilisé' AND LOWER(detail) LIKE '%financ%'
                THEN 'Immobilisations financières'
            
            WHEN poste = 'Actif immobilisé' AND LOWER(detail) LIKE '%droits de retour%'
                THEN 'Droits de retour'
            
            WHEN poste = 'Actif immobilisé' AND LOWER(detail) LIKE '%en cours%'
                THEN 'Immobilisations en cours'
            
            WHEN poste = 'Actif immobilisé'
                THEN 'Immobilisations corporelles'
            
            -- Autres postes: reprendre le poste
            ELSE poste
        END AS categorie_analytique
        
    FROM aggregated
    -- On garde TOUTES les lignes, même celles avec montant = 0
    -- Un poste à 0€ est une information valide en comptabilité
)

SELECT * FROM final
