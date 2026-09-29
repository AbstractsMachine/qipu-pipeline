{{
  config(
    enabled=true,
    materialized='table',
    tags=['national', 'marts']
  )
}}

/*
  Mart: qui décide — le maire et la taille du conseil, une ligne par commune.
  Publié : nom, prénom, fonction, date de début de fonction, nombre de
  conseillers et d'adjoints. Rien d'autre du répertoire.

  Depuis quand (2026-09-15). Le répertoire courant ne connaît que la fonction
  en cours : au lendemain des municipales il dit « depuis mars 2026 » d'un
  maire en poste depuis 2014. Les versions archivées du fichier des maires
  (stg_rne_maires_historique, une capture par an 2020-2025) permettent de
  remonter la chaîne : en partant du maire courant, on parcourt les captures
  de la plus récente à la plus ancienne tant que la même personne (nom +
  prénom normalisés, rne_nom_norm) est maire de la même commune ; la première
  capture où la personne diffère ou manque arrête la chaîne.
    maire_depuis_premier  la plus ancienne date de début de fonction de la chaîne
    maire_depuis_borne    vrai quand la chaîne atteint la plus ancienne capture :
                          la personne était déjà maire avant, on dit « au moins »
    mandats               les années de début de fonction de la chaîne, croissantes,
                          « 2014,2020,2026 »
  Une commune absente de l'historique (commune nouvelle, code changé) garde le
  seul mandat courant.
*/

WITH elus AS (
    SELECT * FROM {{ ref('stg_rne_conseillers_municipaux') }}
),

maire AS (
    SELECT
        code_insee, nom, prenom, date_debut_fonction,
        {{ rne_nom_norm('nom') }}    AS nom_n,
        {{ rne_nom_norm('prenom') }} AS prenom_n
    FROM elus
    WHERE fonction IS NOT NULL AND REGEXP_CONTAINS(fonction, r'^(?i)maire$')
    QUALIFY ROW_NUMBER() OVER (PARTITION BY code_insee ORDER BY date_debut_fonction DESC) = 1
),

conseil AS (
    SELECT
        code_insee,
        ANY_VALUE(commune_nom) AS commune_nom,
        COUNT(*) AS nb_conseillers,
        COUNTIF(REGEXP_CONTAINS(COALESCE(fonction, ''), r'(?i)adjoint')) AS nb_adjoints,
        MAX(date_debut_mandat) AS date_debut_mandat
    FROM elus
    GROUP BY code_insee
),

-- L'historique : un maire par commune et par capture. Quand une capture porte
-- deux lignes pour la même commune (passation en cours), la fonction la plus
-- récente.
historique AS (
    SELECT
        code_insee, snapshot_date, date_debut_fonction,
        {{ rne_nom_norm('nom') }}    AS nom_n,
        {{ rne_nom_norm('prenom') }} AS prenom_n
    FROM {{ ref('stg_rne_maires_historique') }}
    QUALIFY ROW_NUMBER() OVER (PARTITION BY code_insee, snapshot_date ORDER BY date_debut_fonction DESC) = 1
),

captures AS (
    SELECT DISTINCT snapshot_date FROM historique
),

-- La grille commune × capture : une case vide quand la commune manque à la
-- capture, pour que le manque arrête la chaîne comme un changement de personne.
grille AS (
    SELECT
        m.code_insee,
        c.snapshot_date,
        h.date_debut_fonction,
        h.code_insee IS NOT NULL AND h.nom_n = m.nom_n AND h.prenom_n = m.prenom_n AS meme_personne
    FROM maire m
    CROSS JOIN captures c
    LEFT JOIN historique h
        ON h.code_insee = m.code_insee AND h.snapshot_date = c.snapshot_date
),

-- La chaîne : de la capture la plus récente à la plus ancienne, une case est
-- dans la chaîne si elle et toutes les plus récentes sont la même personne.
chaine AS (
    SELECT
        *,
        MIN(IF(meme_personne, 1, 0)) OVER (
            PARTITION BY code_insee ORDER BY snapshot_date DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) = 1 AS dans_chaine
    FROM grille
),

chaine_agg AS (
    SELECT
        code_insee,
        MIN(date_debut_fonction)                                                AS depuis_premier,
        COUNT(*) = (SELECT COUNT(*) FROM captures)                              AS borne,
        ARRAY_AGG(DISTINCT EXTRACT(YEAR FROM date_debut_fonction) IGNORE NULLS) AS annees
    FROM chaine
    WHERE dans_chaine
    GROUP BY code_insee
)

SELECT
    c.code_insee,
    c.commune_nom,
    m.nom       AS maire_nom,
    m.prenom    AS maire_prenom,
    m.date_debut_fonction AS maire_depuis,
    -- Le mandat courant fait partie de la chaîne : jamais plus tard que maire_depuis.
    IF(m.code_insee IS NULL, NULL,
       (SELECT MIN(d) FROM UNNEST([m.date_debut_fonction, h.depuis_premier]) d)) AS maire_depuis_premier,
    IF(m.code_insee IS NULL, NULL, COALESCE(h.borne, FALSE))                     AS maire_depuis_borne,
    IF(m.code_insee IS NULL, NULL,
       (SELECT STRING_AGG(DISTINCT CAST(y AS STRING), ',' ORDER BY CAST(y AS STRING))
        FROM UNNEST(ARRAY_CONCAT(
            IF(m.date_debut_fonction IS NULL, [], [EXTRACT(YEAR FROM m.date_debut_fonction)]),
            COALESCE(h.annees, [])
        )) y))                                                                    AS mandats,
    c.nb_conseillers,
    c.nb_adjoints,
    c.date_debut_mandat
FROM conseil c
LEFT JOIN maire m USING (code_insee)
LEFT JOIN chaine_agg h USING (code_insee)
