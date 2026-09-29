-- =============================================================================
-- Core: Subventions (OBT, ex-int_subventions_enrichies aplatie)
--
-- Sources:
--   - stg_subventions_all                   (lignes brutes)
--   - stg_associations                      (siret + direction + objet par asso)
--   - stg_mapping_beneficiaires             (regex pattern → thematique)
--   - stg_mapping_directions                (direction → thematique)
--   - stg_cache_thematique_beneficiaires    (cache LLM thematique)
--   - stg_mapping_entites                   (regex pattern → nom canonique)
--
-- Grain: une ligne par subvention (cle_technique).
--
-- Pas de géolocalisation : les subventions vont à des organisations, pas à des
-- lieux. L'adresse du siège ne reflète pas où l'action est menée.
--
-- Enrichissements (ode_*) :
--   - ode_thematique         (cascade: pattern → direction → llm → default)
--   - ode_sous_categorie     (pattern ou llm)
--   - ode_source_thematique  ('pattern' | 'direction' | 'llm' | 'default')
--   - ode_type_organisme     (public | association | entreprise | …)
--   - ode_contribution_nature (bool)
--   - ode_beneficiaire_canonique (déduplication CASP etc.)
--   - ode_identite / ode_nom_identite (identité de l'organisation toutes
--     années, depuis dim_beneficiaire ; ode_nom_identite NULL si la graphie
--     n'est rapprochée d'aucune autre)
--
-- Output: ~53k lignes, 2018-2024.
-- =============================================================================

WITH subventions AS (
    SELECT * FROM {{ ref('stg_subventions_all') }}
),

associations AS (
    SELECT * FROM {{ ref('stg_associations') }}
),

mapping_beneficiaires AS (
    SELECT * FROM {{ ref('stg_mapping_beneficiaires') }}
),

mapping_directions AS (
    SELECT * FROM {{ ref('stg_mapping_directions') }}
),

cache_thematique AS (
    SELECT * FROM {{ ref('stg_cache_thematique_beneficiaires') }}
),

mapping_entites AS (
    SELECT * FROM {{ ref('stg_mapping_entites') }}
),

-- Identité de l'organisation (registre dim_beneficiaire, toutes années).
identites AS (
    SELECT beneficiaire_normalise, identite, nom_identite
    FROM {{ ref('dim_beneficiaire') }}
),

-- ─── ÉTAPE 1 : Dédupliquer associations pour le JOIN ───────────────────────────
-- Une ligne par (beneficiaire_normalise, annee). Priorité au dossier avec le
-- plus gros montant (représente mieux l'activité principale).
associations_dedup AS (
    SELECT
        beneficiaire_normalise,
        annee,
        siret,
        direction,
        objet,
        secteurs_activite,
        -- Tiebreaker stable (siret ASC) pour reproductibilité quand
        -- plusieurs lignes ont le même montant.
        ROW_NUMBER() OVER (
            PARTITION BY beneficiaire_normalise, annee
            ORDER BY montant DESC,
                     COALESCE(siret, '') ASC,
                     COALESCE(direction, '') ASC
        ) AS rn
    FROM associations
),

associations_unique AS (
    SELECT
        beneficiaire_normalise,
        annee,
        siret,
        direction,
        objet,
        secteurs_activite
    FROM associations_dedup
    WHERE rn = 1
),

-- ─── ÉTAPE 2 : Pattern matching pour thematique ────────────────────────────────
distinct_beneficiaires AS (
    SELECT DISTINCT beneficiaire_normalise
    FROM subventions
    WHERE beneficiaire_normalise IS NOT NULL
),

pattern_matches AS (
    SELECT
        b.beneficiaire_normalise,
        m.thematique,
        m.sous_categorie,
        m.priorite,
        ROW_NUMBER() OVER (
            PARTITION BY b.beneficiaire_normalise
            -- Tie-break on the pattern text so equal-priority regex matches
            -- resolve deterministically (else thematique can flip between builds).
            ORDER BY m.priorite ASC, m.pattern ASC
        ) AS rn
    FROM distinct_beneficiaires b
    CROSS JOIN mapping_beneficiaires m
    WHERE REGEXP_CONTAINS(b.beneficiaire_normalise, m.pattern)
),

best_pattern AS (
    SELECT
        beneficiaire_normalise,
        thematique AS pattern_thematique,
        sous_categorie AS pattern_sous_categorie
    FROM pattern_matches
    WHERE rn = 1
),

-- ─── ÉTAPE 3 : Canonicalisation entité (CASP etc.) ─────────────────────────────
entity_matches AS (
    SELECT
        b.beneficiaire_normalise,
        e.nom_canonique,
        ROW_NUMBER() OVER (
            PARTITION BY b.beneficiaire_normalise
            -- Tie-break on the pattern text so equal-length patterns resolve
            -- to a fixed canonical name across builds.
            ORDER BY LENGTH(e.pattern) DESC, e.pattern ASC
        ) AS rn
    FROM distinct_beneficiaires b
    CROSS JOIN mapping_entites e
    WHERE REGEXP_CONTAINS(b.beneficiaire_normalise, e.pattern)
),

best_entity AS (
    SELECT beneficiaire_normalise, nom_canonique
    FROM entity_matches
    WHERE rn = 1
),

-- ─── ÉTAPE 4 : JOIN des enrichissements ────────────────────────────────────────
joined AS (
    SELECT
        s.*,
        a.siret,
        a.direction,
        a.objet,
        a.secteurs_activite,
        bp.pattern_thematique,
        bp.pattern_sous_categorie,
        md.thematique AS direction_thematique,
        ct.ode_thematique AS llm_thematique,
        ct.ode_sous_categorie AS llm_sous_categorie,
        be.nom_canonique AS matched_nom_canonique,
        idt.identite AS matched_identite,
        idt.nom_identite AS matched_nom_identite
    FROM subventions s
    LEFT JOIN associations_unique a
        ON s.beneficiaire_normalise = a.beneficiaire_normalise
        AND s.annee = a.annee
    LEFT JOIN best_pattern bp
        ON s.beneficiaire_normalise = bp.beneficiaire_normalise
    LEFT JOIN mapping_directions md
        ON a.direction = md.direction
    LEFT JOIN cache_thematique ct
        ON s.beneficiaire_normalise = ct.beneficiaire_normalise
    LEFT JOIN best_entity be
        ON s.beneficiaire_normalise = be.beneficiaire_normalise
    LEFT JOIN identites idt
        ON s.beneficiaire_normalise = idt.beneficiaire_normalise
)

-- ─── ÉTAPE 5 : Construction des colonnes ode_* ─────────────────────────────────
SELECT
    annee,
    beneficiaire,
    beneficiaire_normalise,
    categorie,
    nature_juridique,
    montant,
    prestations_nature,
    collectivite,
    donnees_disponibles,
    cle_technique,

    siret,
    direction,
    objet,
    secteurs_activite,

    -- Cascade thematique : pattern → direction → llm → fallback catégorie
    COALESCE(
        pattern_thematique,
        direction_thematique,
        llm_thematique,
        CASE
            WHEN categorie LIKE '%culture%' OR categorie LIKE '%spectacle%' THEN 'Culture'
            WHEN categorie LIKE '%sport%' THEN 'Sport'
            WHEN categorie LIKE '%social%' OR categorie LIKE '%solidarit%' THEN 'Social'
            WHEN categorie LIKE '%education%' OR categorie LIKE '%scolaire%' THEN 'Éducation'
            WHEN categorie LIKE '%environnement%' OR categorie LIKE '%ecolog%' THEN 'Environnement'
            WHEN nature_juridique = 'Entreprises' THEN 'Économie'
            WHEN nature_juridique = 'Établissements publics' THEN 'Administration'
            ELSE 'Non classifié'
        END
    ) AS ode_thematique,

    COALESCE(pattern_sous_categorie, llm_sous_categorie) AS ode_sous_categorie,

    CASE
        WHEN pattern_thematique IS NOT NULL THEN 'pattern'
        WHEN direction_thematique IS NOT NULL THEN 'direction'
        WHEN llm_thematique IS NOT NULL THEN 'llm'
        ELSE 'default'
    END AS ode_source_thematique,

    CASE nature_juridique
        WHEN 'Etablissements publics' THEN 'public'
        WHEN 'Etablissements de droit public' THEN 'public'
        WHEN 'Etat' THEN 'public'
        WHEN 'Communes' THEN 'public'
        WHEN 'Département' THEN 'public'
        WHEN 'Régions' THEN 'public'
        WHEN 'Autres personnes de droit public' THEN 'public'
        WHEN 'Associations' THEN 'association'
        WHEN 'Entreprises' THEN 'entreprise'
        WHEN 'Personnes physiques' THEN 'personne_physique'
        WHEN 'Autres personnes de droit privé' THEN 'prive_autre'
        WHEN 'Autres' THEN 'autre'
        ELSE 'non_renseigne'
    END AS ode_type_organisme,

    CASE
        WHEN prestations_nature IS NOT NULL AND prestations_nature > 0 THEN TRUE
        ELSE FALSE
    END AS ode_contribution_nature,

    COALESCE(matched_nom_canonique, beneficiaire_normalise) AS ode_beneficiaire_canonique,

    COALESCE(matched_identite, beneficiaire_normalise) AS ode_identite,
    matched_nom_identite AS ode_nom_identite,

    CURRENT_TIMESTAMP() AS _dbt_updated_at

FROM joined
