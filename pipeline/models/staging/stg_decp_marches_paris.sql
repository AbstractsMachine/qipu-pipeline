-- =============================================================================
-- Staging: DECP Marchés Paris
--
-- Source: raw.decp_marches_paris (data.gouv.fr — DECP consolidés filtrés Paris)
--
-- Grain: un marché unique identifié par `id` (10 char, ex: "2024T05699").
-- Pour les marchés remontés plusieurs années de suite (publication initiale +
-- modifications années suivantes), on garde la ligne la plus récente via
-- ROW_NUMBER sur (id, source_year DESC).
--
-- Usage côté core: LEFT JOIN core_marches_publics via
--   SUBSTR(liste_des_marches.num_marche, 5) = stg_decp.id
-- =============================================================================
{{ config(materialized='view') }}

WITH source AS (
    SELECT *
    FROM {{ source('paris_raw', 'decp_marches_paris') }}
    WHERE id IS NOT NULL
),

dedup AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY id
            ORDER BY source_year DESC, date_publication_donnees DESC
        ) AS rn
    FROM source
),

cleaned AS (
    SELECT
        -- =====================================================================
        -- IDENTIFIANTS
        -- =====================================================================
        id AS decp_id,
        uid AS decp_uid,
        source_year,

        -- =====================================================================
        -- MARCHÉ
        -- =====================================================================
        nature,
        -- Apostrophe mal encodée par l'acheteur (« d¿articles ») : voir stg_decp_marches.
        REGEXP_REPLACE(objet, r'(\pL)¿(\pL)', r'\1’\2') AS objet,
        procedure AS type_procedure,
        forme_prix,
        SAFE_CAST(date_notification AS DATE) AS date_notification,
        SAFE_CAST(date_publication_donnees AS DATE) AS date_publication_donnees,
        SAFE_CAST(EXTRACT(YEAR FROM SAFE_CAST(date_notification AS DATE)) AS INT64) AS annee_notification,
        duree_mois,

        -- =====================================================================
        -- CATÉGORISATION (apport clé de DECP)
        -- =====================================================================
        ccag,                                              -- Travaux | Fournitures | PI | MOE | TIC
        code_cpv,
        SUBSTR(CAST(code_cpv AS STRING), 1, 2) AS cpv_division,

        -- =====================================================================
        -- MONTANT NOTIFIÉ (≠ plafond Paris !)
        -- =====================================================================
        montant AS montant_notifie,

        -- =====================================================================
        -- LIEU D'EXÉCUTION (apport clé)
        -- =====================================================================
        lieu_execution_code,
        lieu_execution_type_code,
        lieu_execution_nom,
        CASE
            WHEN lieu_execution_type_code IN ('Code postal', 'Code Postal')
                 AND STARTS_WITH(CAST(lieu_execution_code AS STRING), '750')
            THEN SAFE_CAST(SUBSTR(CAST(lieu_execution_code AS STRING), 4, 2) AS INT64)
            WHEN lieu_execution_type_code = 'Code département'
                 AND lieu_execution_code = '75'
            THEN 0  -- marché exécuté à Paris, arrondissement non précisé
            ELSE NULL
        END AS arrondissement_exec,

        -- =====================================================================
        -- ACHETEUR
        -- =====================================================================
        acheteur_id AS acheteur_siret,
        acheteur_nom,

        -- =====================================================================
        -- TITULAIRES
        -- =====================================================================
        titulaire_siret,
        titulaire_nom,
        titulaires_sirets,
        titulaires_count,

        -- =====================================================================
        -- QUALITÉ & SIGNAUX
        -- =====================================================================
        offres_recues,
        type_groupement_operateurs,
        CAST(marche_innovant AS BOOL) AS marche_innovant,
        CAST(sous_traitance_declaree AS BOOL) AS sous_traitance_declaree,
        nb_modifications,

        -- =====================================================================
        -- CONSIDERATIONS RSE
        -- =====================================================================
        considerations_sociales,
        considerations_environnementales,
        CAST(has_consideration_sociale AS BOOL) AS has_consideration_sociale,
        CAST(has_consideration_environnementale AS BOOL) AS has_consideration_environnementale

    FROM dedup
    WHERE rn = 1
)

SELECT * FROM cleaned
