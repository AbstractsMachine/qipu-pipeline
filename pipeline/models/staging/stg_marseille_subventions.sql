-- =============================================================================
-- Staging: Marseille subventions (SCDL Ville, data.gouv.fr)
--
-- Sources: raw.marseille_subventions_ville_{2017..2022} (synced via sync_city.py
--   marseille --source marseille_subventions_ville, loaded all-STRING — see below).
--
-- ⚠ Locale number format: the SCDL `montant` mixes French decimal comma
--   ("854999,98" = 854 999,98 €) AND dot decimal ("15031.65") — sometimes within
--   the same file. BigQuery autodetect strips the comma (854999,98 → 85499998,
--   a ×100 inflation), so the raw tables are loaded all-STRING (all_strings:true
--   in marseille.yaml) and montant is cast HERE: strip spaces, comma→dot, cast.
--
-- ⚠ Header case drift: 2018 publishes `TypeBeneficiaire` (capital T); all other
--   years `typeBeneficiaire`. (Trailing-space variants are normalised away by the
--   all-STRING loader's header sanitiser.)
--
-- Output aligned with stg_subventions_all (Paris) so the shared subventions
-- marts + exporter apply unchanged, plus commune_slug ('marseille') and objet
-- (from objetAideNature — a per-line signal that feeds the LLM thematique prompt).
--
-- Marseille SCDL carries NO siret, NO direction, NO catégorie dimension — the
-- thematique comes from the in-session LLM cache (stg_marseille_cache_thematique)
-- keyed on beneficiaire_normalise, cascaded in core_marseille_subventions.
--
-- Personnes physiques : le SCDL nomme les particuliers (prénom + nom, 2020-2022).
-- Comme pour Paris, ils ne sont jamais publiés sous leur nom : UNE ligne agrégée
-- par exercice (« Personnes physiques anonymisées RGPD (N aides individuelles) »),
-- total de l'exercice inchangé. Garde-fou : audit/check_personnes_physiques.py.
-- =============================================================================

{{ config(materialized='view', schema='staging', tags=['staging', 'marseille', 'subventions']) }}

{% set type_ben_col = {
    2017: 'typeBeneficiaire',
    2018: 'TypeBeneficiaire',
    2019: 'typeBeneficiaire',
    2020: 'typeBeneficiaire',
    2021: 'typeBeneficiaire',
    2022: 'typeBeneficiaire',
} %}

WITH unioned AS (
    {% for year, tb_col in type_ben_col.items() %}
    SELECT
        COALESCE(SAFE_CAST(`anneeAttribution` AS INT64), {{ year }}) AS annee,
        TRIM(`nomBeneficiaire`) AS beneficiaire_raw,
        TRIM(`{{ tb_col }}`) AS type_beneficiaire,
        -- Parse locale-formatted amount: strip spaces (any thousands spacing),
        -- comma → dot decimal, then cast. Handles both "854999,98" and "15031.65".
        SAFE_CAST(REPLACE(REPLACE(`montant`, ' ', ''), ',', '.') AS FLOAT64) AS montant_raw,
        `nature` AS nature_aide,
        `objetAideNature` AS objet_raw
    FROM {{ source('marseille_raw', 'marseille_subventions_ville_' ~ year) }}
    {% if not loop.last %}UNION ALL{% endif %}
    {% endfor %}
),

normalised AS (
    SELECT
        'marseille' AS commune_slug,
        'Marseille' AS collectivite,
        annee,
        beneficiaire_raw AS beneficiaire,

        -- Bénéficiaire normalisé — MÊME transformation que stg_subventions_all
        -- (Paris) pour que la jointure thematique + le dédoublonnage search
        -- soient cohérents entre villes.
        UPPER(TRIM(REGEXP_REPLACE(
            REGEXP_REPLACE(
                REGEXP_REPLACE(
                    COALESCE(beneficiaire_raw, ''),
                    r"^(L'|LA |LE |LES |D'|DU |DE LA |DE L'|DES )", ''
                ),
                r'[^A-Za-zÀ-ÿ0-9\s]', ' '
            ),
            r'\s+', ' '
        ))) AS beneficiaire_normalise,

        -- Pas de dimension "catégorie" dans le SCDL Marseille : on porte la
        -- nature de l'aide (numéraire/nature) — inoffensif pour le fallback
        -- Paris (qui matche sur des mots-clés culture/sport/… absents ici ;
        -- le cache LLM est le vrai chemin thematique).
        nature_aide AS categorie,
        type_beneficiaire AS nature_juridique,
        montant_raw AS montant,

        -- Prestations en nature : le SCDL distingue "aide en nature" vs
        -- "aide en numéraire" par ligne → montant si en nature, sinon NULL.
        CASE
            WHEN LOWER(COALESCE(nature_aide, '')) LIKE '%nature%' THEN montant_raw
            ELSE NULL
        END AS prestations_nature,

        NULLIF(TRIM(objet_raw), '') AS objet,
        TRUE AS donnees_disponibles,
        'scdl_datagouv' AS source_systeme,

        CONCAT(
            'marseille-subv-', CAST(annee AS STRING), '-',
            SUBSTR(TO_HEX(MD5(CONCAT(
                COALESCE(beneficiaire_raw, ''), '|',
                CAST(montant_raw AS STRING), '|',
                COALESCE(objet_raw, '')
            ))), 1, 16)
        ) AS cle_technique

    FROM unioned
    WHERE beneficiaire_raw IS NOT NULL
      AND TRIM(beneficiaire_raw) != ''
      AND COALESCE(montant_raw, 0) > 0
),

personnes_physiques AS (
    SELECT
        'marseille' AS commune_slug,
        'Marseille' AS collectivite,
        annee,
        CONCAT(
            'Personnes physiques anonymisées RGPD (',
            CAST(COUNT(*) AS STRING),
            ' aides individuelles)'
        ) AS beneficiaire,
        'PERSONNES PHYSIQUES ANONYMISEES RGPD' AS beneficiaire_normalise,
        CAST(NULL AS STRING) AS categorie,
        'Personnes physiques' AS nature_juridique,
        SUM(montant) AS montant,
        SUM(prestations_nature) AS prestations_nature,
        CAST(NULL AS STRING) AS objet,
        TRUE AS donnees_disponibles,
        'scdl_datagouv' AS source_systeme,
        CONCAT('marseille-subv-', CAST(annee AS STRING), '-PP-RGPD-AGGR') AS cle_technique
    FROM normalised
    WHERE nature_juridique = 'Personnes physiques'
    GROUP BY annee
),

-- Homonymes : une ligne d'une autre nature privée (hors associations et
-- personnes publiques) dont le nom exact est étiqueté « Personnes physiques »
-- un autre exercice (ex. un particulier classé « Entreprises » avec son
-- adresse) est agrégée par exercice et nature, comme pour Paris.
noms_personnes_physiques AS (
    SELECT DISTINCT UPPER(TRIM(REGEXP_REPLACE(beneficiaire, r'\s+', ' '))) AS cle_nom
    FROM normalised
    WHERE nature_juridique = 'Personnes physiques'
),

flagged AS (
    SELECT
        n.*,
        COALESCE(
            COALESCE(n.nature_juridique, '') != 'Personnes physiques'
            AND COALESCE(n.nature_juridique, '') NOT IN (
                'Associations', 'Etablissements publics', 'Établissements publics',
                'Autres personnes de droit public', 'Etat', 'État', 'Communes',
                'Département', 'Départements', 'Régions'
            )
            AND pp.cle_nom IS NOT NULL,
            FALSE
        ) AS homonyme_particulier
    FROM normalised n
    LEFT JOIN noms_personnes_physiques pp
        ON UPPER(TRIM(REGEXP_REPLACE(n.beneficiaire, r'\s+', ' '))) = pp.cle_nom
),

homonymes_agreges AS (
    SELECT
        'marseille' AS commune_slug,
        'Marseille' AS collectivite,
        annee,
        CONCAT(
            'Bénéficiaires non nommés — ', COALESCE(nature_juridique, '—'),
            ", même nom qu'un particulier (", CAST(COUNT(*) AS STRING),
            IF(COUNT(*) = 1, ' ligne)', ' lignes)')
        ) AS beneficiaire,
        CONCAT('BENEFICIAIRES NON NOMMES HOMONYMES PARTICULIERS ', UPPER(COALESCE(nature_juridique, '—'))) AS beneficiaire_normalise,
        MIN(categorie) AS categorie,
        nature_juridique,
        SUM(montant) AS montant,
        SUM(prestations_nature) AS prestations_nature,
        CAST(NULL AS STRING) AS objet,
        TRUE AS donnees_disponibles,
        'scdl_datagouv' AS source_systeme,
        CONCAT('marseille-subv-', CAST(annee AS STRING), '-HOMONYMES-PP-',
               SUBSTR(TO_HEX(MD5(COALESCE(nature_juridique, '—'))), 1, 6)) AS cle_technique
    FROM flagged
    WHERE homonyme_particulier
    GROUP BY annee, nature_juridique
)

SELECT * EXCEPT (homonyme_particulier) FROM flagged
WHERE COALESCE(nature_juridique, '') != 'Personnes physiques'
  AND NOT homonyme_particulier
UNION ALL
SELECT * FROM personnes_physiques
UNION ALL
SELECT * FROM homonymes_agreges
