-- =============================================================================
-- DIM : Bénéficiaires de subventions — registre d'identité persistant
--
-- Grain : une ligne par `beneficiaire_normalise` (l'identité entité,
--         indépendante de l'année).
--
-- RAISON D'ÊTRE
-- L'identité d'un bénéficiaire ne repose sur AUCUN identifiant stable en source :
-- l'annexe CA (source autoritaire, stg_subventions_all) ne porte pas de SIRET —
-- seulement un nom normalisé. Résultat : tout l'enrichissement (thématique LLM,
-- SIRET, nom canonique) se jointait sur cette chaîne, et la regex de
-- normalisation était recopiée dans ≥4 fichiers ; une divergence orphelinait
-- silencieusement le cache LLM (247 orgs retombées en « Non classifié »).
--
-- Ce dim est le SEUL endroit qui :
--   1. énumère les entités distinctes,
--   2. leur attribue un `beneficiaire_id` de substitution STABLE,
--   3. résout l'enrichissement niveau-entité (SIRET/SIREN, thématique, canon).
-- Les faits en aval REJOIGNENT ce dim au lieu de ré-implémenter la normalisation
-- et les jointures de cache. Le crosswalk (normalise → id) est capturé par
-- snap_dim_beneficiaire pour survivre à un futur changement de normalisation.
--
-- NB : particuliers exclus de la résolution SIRET/thématique — la source les
-- agrège déjà en une ligne « PERSONNES PHYSIQUES ANONYMISEES RGPD » au staging.
--
-- IDENTITÉ (2026-09-29) : une même organisation est publiée sous plusieurs
-- graphies selon les exercices (nom coupé à 35 caractères, sigle, abréviation :
-- « REGIE IMMOBILIERE DE LA VILLE DE PA », « RIVP », « REGIE IMMOBILIERE VILLE
-- DE PARIS RIVP »). `identite` rattache chaque graphie à la graphie canonique
-- de son organisation (stg_beneficiaire_identites, preuve par graphie), pour
-- toutes les années ; une graphie non rapprochée est sa propre identité.
-- `nom_identite` = le nom publié le plus récent de la graphie canonique, NULL
-- quand la graphie n'est rapprochée d'aucune autre (le nom source reste alors
-- celui de chaque ligne). Jamais de personne physique dans le seed.
-- =============================================================================

WITH distinct_benef AS (
    SELECT DISTINCT beneficiaire_normalise
    FROM {{ ref('stg_subventions_all') }}
    WHERE beneficiaire_normalise IS NOT NULL
),

mapping_beneficiaires AS (
    SELECT * FROM {{ ref('stg_mapping_beneficiaires') }}
),

mapping_entites AS (
    SELECT * FROM {{ ref('stg_mapping_entites') }}
),

cache_thematique AS (
    SELECT * FROM {{ ref('stg_cache_thematique_beneficiaires') }}
),

identites AS (
    SELECT beneficiaire_normalise, identite
    FROM {{ ref('stg_beneficiaire_identites') }}
),

-- Le nom publié le plus récent de chaque graphie (à égalité d'exercice, la
-- ligne au plus gros montant) : sert de nom d'affichage à l'identité.
nom_recent AS (
    SELECT
        beneficiaire_normalise,
        ARRAY_AGG(beneficiaire IGNORE NULLS ORDER BY annee DESC, montant DESC, cle_technique)[SAFE_OFFSET(0)] AS nom
    FROM {{ ref('stg_subventions_all') }}
    WHERE beneficiaire_normalise IS NOT NULL
    GROUP BY beneficiaire_normalise
),

-- ─── SIRET / secteurs au niveau ENTITÉ ────────────────────────────────────────
-- Une association peut varier par année (dossiers multiples) ; le SIRET, lui,
-- est stable par entité. On retient la valeur du plus gros dossier (déterministe,
-- IGNORE NULLS) — même logique « dominant grant wins » que les marts.
assoc_entity AS (
    SELECT
        beneficiaire_normalise,
        ARRAY_AGG(siret IGNORE NULLS ORDER BY montant DESC, cle_technique)[SAFE_OFFSET(0)]              AS siret,
        ARRAY_AGG(secteurs_activite IGNORE NULLS ORDER BY montant DESC, cle_technique)[SAFE_OFFSET(0)]  AS secteurs_activite
    FROM {{ ref('stg_associations') }}
    GROUP BY beneficiaire_normalise
),

-- ─── Pattern matching thématique (regex seed) ─────────────────────────────────
pattern_matches AS (
    SELECT
        b.beneficiaire_normalise,
        m.thematique,
        m.sous_categorie,
        ROW_NUMBER() OVER (
            PARTITION BY b.beneficiaire_normalise
            ORDER BY m.priorite ASC, m.pattern ASC
        ) AS rn
    FROM distinct_benef b
    CROSS JOIN mapping_beneficiaires m
    WHERE REGEXP_CONTAINS(b.beneficiaire_normalise, m.pattern)
),

best_pattern AS (
    SELECT
        beneficiaire_normalise,
        thematique      AS pattern_thematique,
        sous_categorie  AS pattern_sous_categorie
    FROM pattern_matches
    WHERE rn = 1
),

-- ─── Canonicalisation entité (CASP etc.) ──────────────────────────────────────
entity_matches AS (
    SELECT
        b.beneficiaire_normalise,
        e.nom_canonique,
        ROW_NUMBER() OVER (
            PARTITION BY b.beneficiaire_normalise
            ORDER BY LENGTH(e.pattern) DESC, e.pattern ASC
        ) AS rn
    FROM distinct_benef b
    CROSS JOIN mapping_entites e
    WHERE REGEXP_CONTAINS(b.beneficiaire_normalise, e.pattern)
),

best_entity AS (
    SELECT beneficiaire_normalise, nom_canonique
    FROM entity_matches
    WHERE rn = 1
)

SELECT
    b.beneficiaire_normalise,

    -- Clé de substitution STABLE. Déterministe (même nom → même id) ET persistée
    -- via snap_dim_beneficiaire, donc l'enrichissement rattaché à l'id survit à
    -- un changement de logique de normalisation.
    TO_HEX(MD5(b.beneficiaire_normalise))                       AS beneficiaire_id,

    -- Identité légale résolue (quand disponible ; NULL sinon — honnête).
    a.siret                                                     AS siret,
    CASE WHEN a.siret IS NOT NULL THEN SUBSTR(a.siret, 1, 9) END AS siren,
    a.secteurs_activite                                        AS secteurs_activite,

    -- Enrichissement thématique niveau-entité (inputs de la cascade ;
    -- l'ordre pattern → llm est appliqué par les faits en aval).
    bp.pattern_thematique,
    bp.pattern_sous_categorie,
    ct.ode_thematique       AS llm_thematique,
    ct.ode_sous_categorie   AS llm_sous_categorie,
    ct.ode_source           AS llm_source_thematique,

    -- Nom canonique (dédup CASP etc.), fallback = le nom normalisé lui-même.
    COALESCE(be.nom_canonique, b.beneficiaire_normalise)        AS nom_canonique,

    -- Identité de l'organisation, toutes années (voir en-tête).
    COALESCE(i.identite, b.beneficiaire_normalise)              AS identite,
    TO_HEX(MD5(COALESCE(i.identite, b.beneficiaire_normalise))) AS identite_id,
    CASE WHEN i.identite IS NOT NULL THEN nr.nom END            AS nom_identite

FROM distinct_benef b
LEFT JOIN assoc_entity  a  USING (beneficiaire_normalise)
LEFT JOIN best_pattern  bp USING (beneficiaire_normalise)
LEFT JOIN cache_thematique ct USING (beneficiaire_normalise)
LEFT JOIN best_entity   be USING (beneficiaire_normalise)
LEFT JOIN identites     i  USING (beneficiaire_normalise)
LEFT JOIN nom_recent    nr ON nr.beneficiaire_normalise = i.identite
