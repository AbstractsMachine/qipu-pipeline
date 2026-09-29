{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}

/*
  Staging : DECP — les marchés de TOUS les acheteurs, un par marché (2026-09-26).

  Le socle commun des marchés des communes (stg_decp_marches, qui n'en garde que
  les acheteurs communes) et de ceux des régions, départements et
  intercommunalités (mart_niveaux_marches, échelle des niveaux). Même
  nettoyage, même déduplication qu'avant le découpage : une ligne par marché
  (acheteur × id — l'id seul se répète d'un acheteur à l'autre), version en
  cours, puis dernière modification, titulaire principal = plus gros montant.
  Vérifié au découpage : stg_decp_marches garde ses 559 141 lignes.
*/

WITH raw AS (
    SELECT
        CAST(uid AS STRING)                          AS marche_id,
        CAST(id AS STRING)                           AS id_acheteur,
        SUBSTR(CAST(acheteur_id AS STRING), 1, 9)    AS acheteur_siren,
        COALESCE(donneesActuelles, FALSE)            AS donnees_actuelles,
        COALESCE(SAFE_CAST(modification_id AS INT64), 0) AS modification_id,
        CAST(acheteur_nom AS STRING)                 AS acheteur_nom,
        -- « d¿articles », « l¿eau » : une apostrophe typographique mal encodée
        -- chez certains acheteurs. « ¿ » n'existe pas en français ; entre deux
        -- lettres, c'est toujours elle (vu le 23/09/2026 : 3 contrats de Lille).
        REGEXP_REPLACE(CAST(objet AS STRING), r'(\pL)¿(\pL)', r'\1’\2') AS objet,
        CAST(nature AS STRING)                       AS nature_marche,
        CAST(procedure AS STRING)                    AS type_procedure,
        CAST(codeCPV AS STRING)                      AS code_cpv,
        LEFT(CAST(codeCPV AS STRING), 2)             AS cpv_division,
        SAFE_CAST(montant AS FLOAT64)                AS montant,
        CAST(formePrix AS STRING)                    AS forme_prix,
        dateNotification                             AS date_notification,
        EXTRACT(YEAR FROM dateNotification)          AS annee,
        SAFE_CAST(dureeMois AS INT64)                AS duree_mois,
        CAST(titulaire_nom AS STRING)                AS titulaire_nom,
        CAST(titulaire_id AS STRING)                 AS titulaire_siret,
        CAST(titulaire_typeIdentifiant AS STRING)    AS titulaire_type_id,
        -- Le détail qui fait une fiche contrat (2026-09-13). « Sans objet » est la
        -- façon DECP de dire « non renseigné » : on le traite comme vide.
        SAFE_CAST(offresRecues AS INT64)             AS offres_recues,
        NULLIF(NULLIF(TRIM(CAST(ccag AS STRING)), ''), 'Sans objet') AS ccag,
        NULLIF(NULLIF(TRIM(CAST(techniques AS STRING)), ''), 'Sans objet') AS techniques,
        NULLIF(NULLIF(TRIM(CAST(considerationsSociales AS STRING)), ''), 'Sans objet') AS considerations_sociales,
        NULLIF(NULLIF(TRIM(CAST(considerationsEnvironnementales AS STRING)), ''), 'Sans objet') AS considerations_environnementales,
        SAFE_CAST(sousTraitanceDeclaree AS BOOL)     AS sous_traitance_declaree,
        NULLIF(TRIM(CAST(lieuExecution_code AS STRING)), '') AS lieu_execution_code,
        UPPER(NULLIF(TRIM(CAST(lieuExecution_typeCode AS STRING)), '')) AS lieu_execution_type,
        NULLIF(TRIM(CAST(idAccordCadre AS STRING)), '') AS id_accord_cadre
    FROM {{ source('national_raw', 'decp_marches') }}
    WHERE montant > 0
      AND dateNotification IS NOT NULL
      -- Plancher 2018 : avant, la DECP est trop lacunaire pour être publiable.
      -- PAS DE PLAFOND. Le « BETWEEN 2018 AND 2025 » qui était écrit ici jetait
      -- silencieusement l'année en cours : au 2026-09-11, 256 872 marchés notifiés
      -- en 2026 étaient dans la table brute et aucun n'atteignait le site, qui
      -- affichait donc 2025 comme dernière année. Un plafond en dur sur une année
      -- se périme le 1er janvier ; on borne au présent, pas à un millésime.
      AND EXTRACT(YEAR FROM dateNotification) >= 2018
      AND dateNotification <= CURRENT_DATE()
),

-- Ce que le dédoublonnage efface, compté avant lui : un marché à plusieurs
-- titulaires (groupement, multi-attributaire) et le nombre d'avenants publiés.
counted AS (
    SELECT
        *,
        COUNT(DISTINCT titulaire_siret) OVER (PARTITION BY acheteur_siren, id_acheteur) AS nb_titulaires,
        MAX(modification_id) OVER (PARTITION BY acheteur_siren, id_acheteur)            AS nb_modifications
    FROM raw
),

-- Une ligne par marché (acheteur × id) : version en cours, puis dernière
-- modification, puis titulaire principal = plus gros montant.
deduped AS (
    SELECT * FROM counted
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY acheteur_siren, id_acheteur
        -- À montant égal (un groupement publie le même montant pour chaque membre), le SIRET
        -- départage : sans lui le titulaire gardé changeait d'un export à l'autre (27/09, #127).
        ORDER BY donnees_actuelles DESC, modification_id DESC, montant DESC, titulaire_siret ASC
    ) = 1
)

SELECT
    marche_id,
    acheteur_siren,
    acheteur_nom,
    objet,
    nature_marche,
    type_procedure,
    code_cpv,
    cpv_division,
    montant,
    forme_prix,
    date_notification,
    annee,
    duree_mois,
    titulaire_nom,
    titulaire_siret,
    IF(titulaire_type_id = 'SIRET', SUBSTR(titulaire_siret, 1, 9), NULL) AS titulaire_siren,
    offres_recues,
    ccag,
    techniques,
    considerations_sociales,
    considerations_environnementales,
    sous_traitance_declaree,
    lieu_execution_code,
    lieu_execution_type,
    id_accord_cadre,
    nb_titulaires,
    nb_modifications
FROM deduped
