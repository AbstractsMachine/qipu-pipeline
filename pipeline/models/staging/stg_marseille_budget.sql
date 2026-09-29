-- =============================================================================
-- Staging: Marseille Budget (BP + CA, M57 par nature)
--
-- Sources: 12 tables annuelles dans raw (synced via sync_city.py marseille):
--   - marseille_budget_primitif_{2018..2024}  (7 années, schéma stable)
--   - marseille_compte_administratif_{2018..2022}  (5 années, ⚠ 2 schémas)
--
-- ⚠ Asymétrie nomenclature vs Paris (cf. docs/marseille-data-inventory.md):
--   Marseille publie en mode VOTE PAR NATURE (chap 11/60/65 = type de charge),
--   PAS en vote fonctionnel comme Paris (chap 930-939 = politique publique).
--   Pas de dimension fonction dans les CSV Marseille → fonction_code = NULL.
--
-- ⚠ 2 schémas CA selon année:
--   - 2018-2019 : "Exercice budgétaire,Budget,Section,Inscription,Type mvt,
--                  Chap,Nature,Alloué,Réalisé"
--   - 2020+     : "BGT_NATDEC,BGT_ANNEE,BGT_SIRET,BGT_NOM,BGT_CONTNAT,
--                  BGT_CONTNAT_LABEL,BGT_NATURE,BGT_NATURE_LABEL,BGT_SECTION,
--                  BGT_OPBUDG,BGT_CODRD,BGT_MTREAL,BGT_MTPREV"
--   BP 2018-2024 : "Doc,Exercice,Budget,Section,Inscription,Type mvt,Chap,
--                   Lib Chap,Nature,Lib. article / nature,Montant BP en euros"
--
-- Output schema (aligned with stg_budget_principal Paris):
--   commune_slug, type_budget, annee, section, sens_flux, type_operation,
--   chapitre_code, chapitre_libelle, nature_code, nature_libelle,
--   fonction_code (NULL), fonction_libelle (NULL), montant, cle_technique
-- =============================================================================

{{ config(materialized='view', schema='staging', tags=['staging', 'marseille']) }}

-- =============================================================================
-- BP (Budget Primitif) — schémas hétérogènes selon l'année.
--
-- ⚠ Data quality data.gouv.fr (audit 2026-05-20 après sync_city.py marseille) :
--   2018 BP : schéma legacy + colonnes désalignées (text dans cols numériques)
--   2019 BP : schéma legacy + montants en centimes (×100) + chiffres incohérents
--   2020 BP : fichier tronqué à 3 colonnes (n'a aucun contenu utilisable)
--   2021 BP : schéma moderne MAIS montants en centimes (×100)
--   2022-2024 BP : schéma moderne, montants en euros (scientific notation `E8`)
--
-- Pour l'instant on n'expose que les années propres et homogènes (2022-2024).
-- Les anciennes années sont COMMENTÉES — si besoin un jour, faudra écrire des
-- branches par année avec unit normalization (×100) explicite + audit du
-- résultat final (cf. project_marseille_v1_decisions).
-- =============================================================================
WITH bp_modern AS (
    {% for year in [2022, 2023, 2024] %}
    SELECT
        'vote' AS type_budget,
        SAFE_CAST(`Exercice` AS INT64) AS annee_raw,
        `Section` AS section_raw,         -- 'FONC' or 'INV'
        `Inscription` AS sens_raw,        -- 'DEP' or 'REC'
        `Type mvt` AS type_op_raw,        -- 'REELS' or 'ORDRE'
        SAFE_CAST(`Chap` AS STRING) AS chapitre_code,
        `Lib Chap` AS chapitre_libelle,
        SAFE_CAST(`Nature` AS STRING) AS nature_code,
        `Lib_ article _ nature` AS nature_libelle,
        CAST(NULL AS STRING) AS fonction_code_raw,
        CAST(NULL AS STRING) AS fonction_libelle_raw,
        SAFE_CAST(`Montant BP en euros` AS FLOAT64) AS montant_raw
    FROM {{ source('marseille_raw', 'marseille_budget_primitif_' ~ year) }}
    -- Budget principal only: the file also carries the 5 budgets annexes
    -- (Opéra et Odéon, Pompes Funèbres, Espaces Evénementiels, Pôle Média
    -- Belle de Mai, Stade Vélodrome) whose nature lines collide on
    -- cle_technique. Aligned with Paris (comptes administratifs *budgets principaux*).
    WHERE `Budget` = 'VdM - Budget Principal'
    {% if not loop.last %}UNION ALL{% endif %}
    {% endfor %}
),

bp_union AS (
    SELECT * FROM bp_modern
),

-- =============================================================================
-- CA legacy — désactivé : CA 2018 a des colonnes désalignées (Réalisé contient
-- des codes nature au lieu de montants pour beaucoup de lignes) ; CA 2019 est
-- un fichier de 4 colonnes truncated. À ré-aborder si data.gouv.fr publie
-- des fichiers propres pour ces années.
-- =============================================================================
ca_legacy AS (
    SELECT
        'execute' AS type_budget,
        CAST(NULL AS INT64) AS annee_raw,
        CAST(NULL AS STRING) AS section_raw,
        CAST(NULL AS STRING) AS sens_raw,
        CAST(NULL AS STRING) AS type_op_raw,
        CAST(NULL AS STRING) AS chapitre_code,
        CAST(NULL AS STRING) AS chapitre_libelle,
        CAST(NULL AS STRING) AS nature_code,
        CAST(NULL AS STRING) AS nature_libelle,
        CAST(NULL AS STRING) AS fonction_code_raw,
        CAST(NULL AS STRING) AS fonction_libelle_raw,
        CAST(NULL AS FLOAT64) AS montant_raw
    FROM UNNEST(CAST([] AS ARRAY<INT64>))  -- zero rows; CTE kept for UNION shape compat
),

-- =============================================================================
-- CA 2020+ (modern schema)
-- =============================================================================
ca_modern AS (
    {% for year in [2020, 2021, 2022] %}
    SELECT
        'execute' AS type_budget,
        SAFE_CAST(`BGT_ANNEE` AS INT64) AS annee_raw,
        -- Section is encoded in BGT_SECTION as 'fonctionnement' or 'investissement'
        CASE
            WHEN UPPER(`BGT_SECTION`) LIKE '%FONCT%' THEN 'FONC'
            WHEN UPPER(`BGT_SECTION`) LIKE '%INVEST%' THEN 'INV'
            ELSE `BGT_SECTION`
        END AS section_raw,
        -- BGT_CODRD = 'recette' or 'depense'
        -- BGT_CODRD = 'dépense' / 'recette' — UPPER('é') is 'É', so '%DEP%'
        -- silently missed every expense line; compare accent-free.
        CASE
            WHEN REGEXP_CONTAINS(NORMALIZE(UPPER(`BGT_CODRD`), NFD), r'^D\p{M}?E\p{M}*P') THEN 'DEP'
            WHEN UPPER(`BGT_CODRD`) LIKE '%REC%' THEN 'REC'
            ELSE `BGT_CODRD`
        END AS sens_raw,
        -- BGT_OPBUDG = 'réel' or 'ordre'
        CASE
            WHEN UPPER(`BGT_OPBUDG`) LIKE '%RÉEL%' OR UPPER(`BGT_OPBUDG`) LIKE '%REEL%' THEN 'REELS'
            ELSE `BGT_OPBUDG`
        END AS type_op_raw,
        SAFE_CAST(`BGT_CONTNAT` AS STRING) AS chapitre_code,
        `BGT_CONTNAT_LABEL` AS chapitre_libelle,
        SAFE_CAST(`BGT_NATURE` AS STRING) AS nature_code,
        `BGT_NATURE_LABEL` AS nature_libelle,
        CAST(NULL AS STRING) AS fonction_code_raw,
        CAST(NULL AS STRING) AS fonction_libelle_raw,
        SAFE_CAST(`BGT_MTREAL` AS FLOAT64) AS montant_raw
    FROM {{ source('marseille_raw', 'marseille_compte_administratif_' ~ year) }}
    -- Budget principal only (BGT_NOM lists the same 5 budgets annexes — see BP).
    WHERE `BGT_NOM` = 'VdM - Budget Principal'
    {% if not loop.last %}UNION ALL{% endif %}
    {% endfor %}
),

-- =============================================================================
-- Union all and normalise to stg_budget_principal-compatible schema
-- =============================================================================
all_lines AS (
    SELECT * FROM bp_union
    UNION ALL
    SELECT * FROM ca_legacy
    UNION ALL
    SELECT * FROM ca_modern
),

normalised AS (
    SELECT
        'marseille' AS commune_slug,
        type_budget,
        annee_raw AS annee,

        -- Section: 'FONC'/'INVE' → 'Fonctionnement'/'Investissement'
        -- ⚠ Marseille publishes 'INVE' (4 chars), not 'INV' like Paris.
        CASE section_raw
            WHEN 'FONC' THEN 'Fonctionnement'
            WHEN 'INVE' THEN 'Investissement'
            WHEN 'INV' THEN 'Investissement'
            ELSE section_raw
        END AS section,

        -- Sens: 'DEP'/'REC' → 'Dépense'/'Recette'
        CASE sens_raw
            WHEN 'DEP' THEN 'Dépense'
            WHEN 'REC' THEN 'Recette'
            ELSE sens_raw
        END AS sens_flux,

        -- Type d'opération
        CASE type_op_raw
            WHEN 'REELS' THEN 'Réel'
            WHEN 'ORDRE' THEN 'Pour Ordre'
            ELSE type_op_raw
        END AS type_operation,

        chapitre_code,
        chapitre_libelle,
        nature_code,
        nature_libelle,

        -- Marseille ne publie la fonction QUE pour les BP 2018-2019 (legacy).
        -- Le reste du temps (2020+, tous les CA), fonction_code/libelle = NULL.
        fonction_code_raw AS fonction_code,
        fonction_libelle_raw AS fonction_libelle,

        ABS(montant_raw) AS montant,

        -- Unique technical key (matches Paris pattern)
        CONCAT(
            'marseille-',
            type_budget, '-',
            CAST(annee_raw AS STRING), '-',
            COALESCE(section_raw, 'X'), '-',
            COALESCE(sens_raw, 'X'), '-',
            COALESCE(chapitre_code, '000'), '-',
            COALESCE(nature_code, '000'), '-',
            SUBSTR(TO_HEX(MD5(COALESCE(nature_libelle, ''))), 1, 8)
        ) AS cle_technique

    FROM all_lines
    WHERE
        -- Keep only real operations (exclude Pour Ordre)
        UPPER(COALESCE(type_op_raw, '')) IN ('REELS', 'RÉEL', 'REEL')
        -- Positive amounts only
        AND COALESCE(montant_raw, 0) > 0
)

SELECT * FROM normalised
