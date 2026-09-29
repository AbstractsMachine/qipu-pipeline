-- =============================================================================
-- Core: Marchés Publics (OBT)
--
-- Sources:
--   - stg_marches_publics (opendata.paris.fr, 17k lignes 2013-2024)
--   - stg_decp_marches_paris (data.gouv DECP nationale, Paris uniquement, 2024+)
--
-- Grain: un marché unique (annee, numero_marche).
--
-- STRATÉGIE DE FUSION :
--   1. Base = stg_marches_publics (montant_max = plafond, la donnée historique Paris).
--   2. LEFT JOIN stg_decp_marches_paris sur SUBSTR(num_marche, 5) = decp_id pour
--      enrichir avec ccag, code_cpv, lieu_execution, offres_recues, montant_notifie.
--   3. UNION les marchés présents UNIQUEMENT dans DECP (~30% en plus, dont des gros
--      marchés absents de la source Paris). On les reconstruit avec num_marche
--      synthétique (annee×2 + decp_id) pour garder un grain stable.
--
-- ⚠️ montant_max = ENVELOPPE AUTORISÉE (plafond contractuel).
-- ⚠️ montant_notifie = montant déclaré à l'État à la signature (DECP), souvent
--    plus réaliste que le plafond pour les accords-cadres mais pas un cumul
--    des bons de commande émis.
--
-- Output: ~17k + ~500/an DECP-exclusifs.
-- =============================================================================

WITH ours AS (
    SELECT *
    FROM {{ ref('stg_marches_publics') }}
    WHERE montant_max > 0
      AND (duree_jours > 0 OR duree_jours IS NULL)
),

decp AS (
    SELECT *
    FROM {{ ref('stg_decp_marches_paris') }}
),

-- =============================================================================
-- MATCHING PARIS ↔ DECP multi-critères
--
-- Contexte : le fichier DECP "2019" (cumulatif, 944 MB) contient des marchés
-- au format legacy `20211120005759` alors que Paris publie `20212021T05759`.
-- Une règle SUBSTR unique rate ~96% des matchs pour 2019-2023 (vérifié en prod).
--
-- Règles de match, par ordre de priorité :
--   0. num_marche == decp_id                      (id identique, 2019-2022)
--   1. SUBSTR(num_marche, 5) == decp_id           (format moderne 2024+)
--   2. (fournisseur_siret, date_notification)     (attrape les legacy)
--      avec tolérance montant |o.max - d.notifie| / o.max < 15%
--
-- La règle 0 est indispensable : sur 2019-2022 Paris et DECP publient le MÊME
-- id (`20212021T01505`), que le SUBSTR de la règle 1 tronque en `2021T01505`.
-- Sans elle, 796 marchés (4,53 Md€) survivaient en double dans le UNION final,
-- gonflant le total 2021 de +34%.
--
-- Un Paris row = 1 DECP match max (ROW_NUMBER sur match_rank).
-- =============================================================================
paris_decp_candidates AS (
    SELECT
        o.numero_marche                             AS paris_num,
        d.decp_id,
        CASE
            WHEN o.numero_marche = d.decp_id THEN 0
            WHEN SUBSTR(o.numero_marche, 5) = d.decp_id THEN 1
            ELSE 2
        END AS match_rank
    FROM ours AS o
    JOIN decp AS d
      ON o.numero_marche = d.decp_id
      OR SUBSTR(o.numero_marche, 5) = d.decp_id
      OR (
            o.fournisseur_siret IS NOT NULL
        AND o.fournisseur_siret = d.titulaire_siret
        AND o.date_notification = d.date_notification
        AND SAFE_DIVIDE(
                ABS(COALESCE(o.montant_max, 0) - COALESCE(d.montant_notifie, 0)),
                NULLIF(o.montant_max, 0)
            ) < 0.15
      )
),

paris_decp_best AS (
    SELECT paris_num, decp_id
    FROM (
        SELECT
            paris_num, decp_id, match_rank,
            ROW_NUMBER() OVER (
                PARTITION BY paris_num
                ORDER BY match_rank, decp_id
            ) AS rn
        FROM paris_decp_candidates
    )
    WHERE rn = 1
),

-- Partie 1 : marchés source Paris, enrichis DECP quand possible.
ours_enriched AS (
    SELECT
        -- Identifiants
        o.annee,
        o.numero_marche,
        o.cle_technique,

        -- Marché (Paris = source de vérité pour objet, car libellé historique)
        o.objet,
        o.nature,

        -- Fournisseur
        o.fournisseur_nom,
        o.fournisseur_siret,
        o.fournisseur_code_postal,
        o.fournisseur_ville,

        -- Montants (Paris = plafond autorisé)
        o.montant_min,
        o.montant_max,

        -- Dates
        o.date_notification,
        o.date_debut,
        o.date_fin,
        o.duree_jours,

        -- Catégorie Paris
        o.categorie_code,
        o.categorie_libelle,
        o.perimetre_financier,

        -- =====================================================================
        -- ENRICHISSEMENT DECP (via paris_decp_best)
        -- =====================================================================
        d.decp_id,
        d.ccag                                      AS decp_ccag,
        d.code_cpv                                  AS decp_code_cpv,
        d.cpv_division                              AS decp_cpv_division,
        d.montant_notifie                           AS decp_montant_notifie,
        d.type_procedure                            AS decp_procedure,
        d.duree_mois                                AS decp_duree_mois,
        d.offres_recues                             AS decp_offres_recues,
        d.lieu_execution_code                       AS decp_lieu_execution_code,
        d.lieu_execution_type_code                  AS decp_lieu_execution_type_code,
        d.arrondissement_exec                       AS decp_arrondissement_exec,
        d.titulaire_siret                           AS decp_titulaire_siret,
        d.titulaires_count                          AS decp_titulaires_count,
        d.sous_traitance_declaree                   AS decp_sous_traitance_declaree,
        d.nb_modifications                          AS decp_nb_modifications,
        d.has_consideration_sociale                 AS decp_has_consideration_sociale,
        d.has_consideration_environnementale        AS decp_has_consideration_environnementale,
        d.marche_innovant                           AS decp_marche_innovant,

        'paris' AS _source_origin  -- ligne provient de opendata.paris.fr
    FROM ours AS o
    LEFT JOIN paris_decp_best AS pd ON pd.paris_num = o.numero_marche
    LEFT JOIN decp AS d ON d.decp_id = pd.decp_id
),

-- Partie 2 : marchés présents UNIQUEMENT dans DECP (non-matchés côté Paris).
--
-- ⚠️ DECP publie les accords-cadres multi-titulaires en N lignes (une par
-- titulaire) avec le MÊME montant dupliqué (le plafond est global, pas par
-- titulaire). Si on somme tel quel, on multiplie le plafond par le nombre
-- de titulaires → gros sur-comptage.
--
-- Dédup: on garde une seule ligne par (objet normalisé, montant, date).
-- Les titulaires multiples sont concaténés.
decp_only_raw AS (
    SELECT
        d.*,
        -- Clé de dédup : même objet / même plafond / même date = même marché
        FARM_FINGERPRINT(CONCAT(
            COALESCE(UPPER(TRIM(d.objet)), ''), '|',
            CAST(COALESCE(d.montant_notifie, 0) AS STRING), '|',
            CAST(COALESCE(d.date_notification, DATE '1900-01-01') AS STRING)
        )) AS _dedup_key
    FROM decp AS d
    -- Anti-join : exclure tous les DECP déjà matchés à un marché Paris
    -- (via SUBSTR ou via SIRET+date+montant).
    LEFT JOIN paris_decp_best AS pd ON pd.decp_id = d.decp_id
    WHERE pd.decp_id IS NULL
      AND d.montant_notifie > 0
      AND d.annee_notification IS NOT NULL
),

decp_only_collapsed AS (
    SELECT
        -- id canonique : le plus petit id alphabétique parmi les doublons.
        MIN(decp_id)                               AS decp_id,
        -- Tous les attributs descriptifs proviennent de CETTE ligne canonique
        -- (MIN_BY sur decp_id) plutôt que d'ANY_VALUE arbitraire : les doublons
        -- DECP décrivent le même marché, donc c'est déterministe et cohérent
        -- avec l'id retenu.
        MIN_BY(annee_notification, decp_id)        AS annee_notification,
        MIN_BY(decp_uid, decp_id)                  AS decp_uid,
        MIN_BY(nature, decp_id)                     AS nature,
        MIN_BY(objet, decp_id)                      AS objet,
        MIN_BY(type_procedure, decp_id)            AS type_procedure,
        MIN_BY(date_notification, decp_id)         AS date_notification,
        MIN_BY(duree_mois, decp_id)                AS duree_mois,
        MIN_BY(ccag, decp_id)                      AS ccag,
        MIN_BY(code_cpv, decp_id)                  AS code_cpv,
        MIN_BY(cpv_division, decp_id)              AS cpv_division,
        MIN_BY(montant_notifie, decp_id)           AS montant_notifie,
        MIN_BY(lieu_execution_code, decp_id)       AS lieu_execution_code,
        MIN_BY(lieu_execution_type_code, decp_id)  AS lieu_execution_type_code,
        MIN_BY(arrondissement_exec, decp_id)       AS arrondissement_exec,
        MIN_BY(offres_recues, decp_id)             AS offres_recues,
        MIN_BY(sous_traitance_declaree, decp_id)   AS sous_traitance_declaree,
        MIN_BY(nb_modifications, decp_id)          AS nb_modifications,
        MIN_BY(has_consideration_sociale, decp_id) AS has_consideration_sociale,
        MIN_BY(has_consideration_environnementale, decp_id) AS has_consideration_environnementale,
        MIN_BY(marche_innovant, decp_id)           AS marche_innovant,
        -- Titulaires : concaténés si multi-attributaire (siret agrégés ;
        -- le nom retenu suit l'id canonique). Ordre FIXÉ : sans ORDER BY,
        -- BigQuery rendait les mêmes SIRET dans un ordre différent à chaque
        -- construction, et la porte de parité voyait 38 « changements » dans
        -- les exports marchés 2024-2026 là où rien n'avait bougé.
        STRING_AGG(DISTINCT CAST(titulaire_siret AS STRING), '|' ORDER BY CAST(titulaire_siret AS STRING)) AS titulaire_siret,
        MIN_BY(titulaire_nom, decp_id)             AS titulaire_nom,
        COUNT(DISTINCT titulaire_siret)            AS titulaires_count,
        COUNT(*)                                   AS _nb_decp_rows  -- diagnostic
    FROM decp_only_raw
    GROUP BY _dedup_key
),

decp_only AS (
    SELECT
        d.annee_notification                                   AS annee,
        -- numero_marche synthétique unique : préfixe "decp-" + id complet.
        -- (Ancienne version SUBSTR(decp_id, 5) pouvait collider entre
        -- formats legacy 14c `20201120014054` et recent 10c `2024T05699`.)
        CONCAT('decp-', d.decp_id)                             AS numero_marche,
        CONCAT('decp-', d.decp_id)                             AS cle_technique,

        d.objet,
        CASE
            WHEN d.ccag = 'Travaux' THEN 'Travaux'
            WHEN d.ccag = 'Fournitures courantes et services' THEN 'Fournitures'
            WHEN d.ccag = "Maitrise d'œuvre" THEN 'Services'
            WHEN d.ccag = 'Prestations intellectuelles' THEN 'Services'
            WHEN d.ccag = "Techniques de l'information et de la communication" THEN 'Services'
            ELSE d.nature
        END AS nature,

        -- Fournisseur : si multi-titulaire (titulaires_count>1 après dédup),
        -- on affiche le badge "MARCHE MULTIATTRIBUTAIRE" comme côté Paris.
        CASE
            WHEN d.titulaires_count > 1 THEN 'MARCHE MULTIATTRIBUTAIRE'
            ELSE CAST(d.titulaire_nom AS STRING)
        END AS fournisseur_nom,
        CAST(d.titulaire_siret AS STRING)                      AS fournisseur_siret,
        CAST(NULL AS STRING)                                   AS fournisseur_code_postal,
        CAST(NULL AS STRING)                                   AS fournisseur_ville,

        CAST(0 AS FLOAT64)                                     AS montant_min,
        d.montant_notifie                                      AS montant_max,

        d.date_notification,
        CAST(NULL AS DATE)                                     AS date_debut,
        CAST(NULL AS DATE)                                     AS date_fin,
        SAFE_CAST(d.duree_mois * 30 AS INT64)                  AS duree_jours,

        CAST(NULL AS STRING)                                   AS categorie_code,
        d.ccag                                                 AS categorie_libelle,
        CAST(NULL AS STRING)                                   AS perimetre_financier,

        d.decp_id,
        d.ccag                                      AS decp_ccag,
        d.code_cpv                                  AS decp_code_cpv,
        d.cpv_division                              AS decp_cpv_division,
        d.montant_notifie                           AS decp_montant_notifie,
        d.type_procedure                            AS decp_procedure,
        d.duree_mois                                AS decp_duree_mois,
        d.offres_recues                             AS decp_offres_recues,
        d.lieu_execution_code                       AS decp_lieu_execution_code,
        d.lieu_execution_type_code                  AS decp_lieu_execution_type_code,
        d.arrondissement_exec                       AS decp_arrondissement_exec,
        d.titulaire_siret                           AS decp_titulaire_siret,
        d.titulaires_count                          AS decp_titulaires_count,
        d.sous_traitance_declaree                   AS decp_sous_traitance_declaree,
        d.nb_modifications                          AS decp_nb_modifications,
        d.has_consideration_sociale                 AS decp_has_consideration_sociale,
        d.has_consideration_environnementale        AS decp_has_consideration_environnementale,
        d.marche_innovant                           AS decp_marche_innovant,

        'decp' AS _source_origin
    FROM decp_only_collapsed AS d
),

unioned AS (
    SELECT * FROM ours_enriched
    UNION ALL
    SELECT * FROM decp_only
)

SELECT
    *,

    -- =====================================================================
    -- COLONNES DÉRIVÉES (frontend-friendly)
    -- =====================================================================
    -- Flag multi-attributaire
    (fournisseur_nom = 'MARCHE MULTIATTRIBUTAIRE') AS is_multiattributaire,

    -- Écart entre plafond Paris et montant notifié DECP
    CASE
        WHEN decp_montant_notifie IS NULL OR montant_max IS NULL THEN NULL
        WHEN montant_max = 0 THEN NULL
        ELSE SAFE_DIVIDE(decp_montant_notifie - montant_max, montant_max)
    END AS ecart_plafond_vs_notifie,

    -- Montant notifié DECP invraisemblable → on ne l'affiche pas.
    --
    -- Deux signatures d'erreur de saisie à la source (DECP est déclaré par
    -- l'acheteur, ici parfois un syndicat type SIPPEREC, pas par la Ville) :
    --   a) notifié >> plafond : impossible par construction pour un accord-cadre,
    --      le notifié ne peut pas dépasser l'enveloppe autorisée. Signature
    --      typique d'une saisie en centimes (×100).
    --      Cas connu : 20191050000015 LINKT/SIPPEREC, 5,5 M€ côté Paris,
    --      550 M€ côté DECP.
    --   b) notifié dérisoire sur un marché conséquent : valeur placeholder.
    --      Cas connus : 3 marchés PHICOGIS EUROPE 2024 notifiés à 10 €.
    --
    -- Le plafond >> notifié n'est PAS suspect : c'est le fonctionnement normal
    -- d'un accord-cadre (enveloppe autorisée vs. commandes réellement passées).
    CASE
        WHEN decp_montant_notifie IS NULL OR montant_max IS NULL THEN FALSE
        WHEN montant_max = 0 THEN FALSE
        WHEN decp_montant_notifie > montant_max * 2 THEN TRUE
        WHEN decp_montant_notifie < 100 AND montant_max > 10000 THEN TRUE
        ELSE FALSE
    END AS decp_montant_notifie_suspect,

    -- Règle d'affichage "double chiffre" : différence > 5%, deux sources
    -- présentes, et montant notifié jugé vraisemblable.
    CASE
        WHEN decp_montant_notifie IS NULL THEN FALSE
        WHEN montant_max = 0 THEN FALSE
        WHEN decp_montant_notifie > montant_max * 2 THEN FALSE
        WHEN decp_montant_notifie < 100 AND montant_max > 10000 THEN FALSE
        WHEN ABS(decp_montant_notifie - montant_max) / montant_max > 0.05 THEN TRUE
        ELSE FALSE
    END AS afficher_deux_montants,

    -- Famille CPV lisible (pour tags UI)
    CASE decp_cpv_division
        WHEN '03' THEN 'Agriculture'
        WHEN '09' THEN 'Énergie / combustibles'
        WHEN '14' THEN 'Matières premières'
        WHEN '15' THEN 'Alimentation'
        WHEN '18' THEN 'Vêtements'
        WHEN '22' THEN 'Imprimerie / édition'
        WHEN '24' THEN 'Produits chimiques'
        WHEN '30' THEN 'Bureau / informatique'
        WHEN '31' THEN 'Équipements électriques'
        WHEN '32' THEN 'Télécommunications'
        WHEN '33' THEN 'Matériel médical'
        WHEN '34' THEN 'Transport'
        WHEN '35' THEN 'Sécurité'
        WHEN '37' THEN 'Musique / sport'
        WHEN '38' THEN 'Instruments laboratoire'
        WHEN '39' THEN 'Mobilier / équipement'
        WHEN '41' THEN 'Eau'
        WHEN '42' THEN 'Machines industrielles'
        WHEN '43' THEN 'Équipements chantiers'
        WHEN '44' THEN 'Matériaux construction'
        WHEN '45' THEN 'Travaux construction'
        WHEN '48' THEN 'Logiciels'
        WHEN '50' THEN 'Réparation / maintenance'
        WHEN '51' THEN 'Installation'
        WHEN '55' THEN 'Hôtellerie / restauration'
        WHEN '60' THEN 'Transport'
        WHEN '63' THEN 'Services auxiliaires transport'
        WHEN '64' THEN 'Postes / télécoms'
        WHEN '65' THEN 'Utilités publiques'
        WHEN '66' THEN 'Finance / assurance'
        WHEN '70' THEN 'Immobilier'
        WHEN '71' THEN 'Architecture / ingénierie'
        WHEN '72' THEN 'Informatique'
        WHEN '73' THEN 'Recherche & développement'
        WHEN '75' THEN 'Administration'
        WHEN '77' THEN 'Services agricoles'
        WHEN '79' THEN 'Services aux entreprises'
        WHEN '80' THEN 'Éducation / formation'
        WHEN '85' THEN 'Santé / social'
        WHEN '90' THEN 'Environnement / propreté'
        WHEN '92' THEN 'Culture / loisirs'
        WHEN '98' THEN 'Services divers'
        ELSE NULL
    END AS decp_cpv_famille,

    -- Lieu d'exécution lisible
    CASE
        WHEN decp_lieu_execution_code = '75' THEN 'Paris'
        WHEN decp_lieu_execution_type_code = 'Code département'
             AND decp_lieu_execution_code IS NOT NULL
        THEN CONCAT('Département ', decp_lieu_execution_code)
        WHEN decp_lieu_execution_type_code IN ('Code postal', 'Code Postal')
             AND STARTS_WITH(CAST(decp_lieu_execution_code AS STRING), '750')
        THEN CONCAT('Paris ',
                    CAST(SAFE_CAST(SUBSTR(CAST(decp_lieu_execution_code AS STRING), 4, 2) AS INT64) AS STRING), 'e')
        WHEN decp_lieu_execution_type_code IN ('Code postal', 'Code Postal')
        THEN CONCAT('CP ', CAST(decp_lieu_execution_code AS STRING))
        ELSE NULL
    END AS decp_lieu_execution_lisible,

    CURRENT_TIMESTAMP() AS _dbt_updated_at

FROM unioned
