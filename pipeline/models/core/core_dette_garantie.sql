-- =============================================================================
-- Core: emprunts garantis Paris (engagements hors bilan)
--
-- Sources: stg_dette_garantie, core_paris_source_catalog (provenance :
--          source_url = page opendata.paris.fr du dataset, jamais en dur)
-- Grain: une ligne par emprunt × annee_de_publication
--
-- Enrichissements:
--   - bucket_nature : classification éditoriale en 3 buckets
--                     (logement_social_aide, logement_hors_aide, autres_operations)
--   - arrondissement: extrait depuis l'objet de l'emprunt via regex CP
--                     parisien (75001..75020 + 75116 → 16e Nord historique)
--   - is_capital_restant_positif : flag pour exclure les emprunts soldés
--
-- Filtre: capital_restant > 0 (les emprunts soldés ne pèsent plus comme HB).
-- =============================================================================

{{ config(materialized='table', schema='analytics', tags=['core','hors_bilan']) }}

WITH provenance AS (
    SELECT dataset_page_url AS source_url
    FROM {{ ref('core_paris_source_catalog') }}
    WHERE source_id = 'dette_garantie'
),

src AS (
    SELECT s.*, p.source_url
    FROM {{ ref('stg_dette_garantie') }} s
    CROSS JOIN provenance p
),

classified AS (
    SELECT
        *,
        -- Bucket éditorial nature
        CASE
            WHEN nature IS NULL THEN 'autres_operations'
            WHEN LOWER(nature) LIKE '%logement%'
                 AND LOWER(nature) LIKE '%aid%'
                 AND (LOWER(nature) LIKE '%etat%' OR LOWER(nature) LIKE '%état%')
                THEN 'logement_social_aide'
            WHEN LOWER(nature) LIKE '%logement%'
                THEN 'logement_hors_aide'
            ELSE 'autres_operations'
        END AS bucket_nature,

        -- Arrondissement extrait depuis l'objet (CP parisien 75001..75020,
        -- + 75116 historique = 16e Nord)
        CASE
            WHEN REGEXP_CONTAINS(IFNULL(objet, ''), r'\b75(\d{3})\b') THEN
                CASE REGEXP_EXTRACT(objet, r'\b75(\d{3})\b')
                    WHEN '116' THEN 16
                    ELSE
                        CASE
                            WHEN SAFE_CAST(REGEXP_EXTRACT(objet, r'\b75(\d{3})\b') AS INT64) BETWEEN 1 AND 20
                                THEN SAFE_CAST(REGEXP_EXTRACT(objet, r'\b75(\d{3})\b') AS INT64)
                            ELSE NULL
                        END
                END
            ELSE NULL
        END AS arrondissement,

        -- Flag taux fixe (commence par F majuscule)
        STARTS_WITH(UPPER(IFNULL(taux_type, '')), 'F') AS is_taux_fixe
    FROM src
)

SELECT *
FROM classified
WHERE capital_restant > 0
