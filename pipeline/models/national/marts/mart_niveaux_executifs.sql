{{
  config(
    enabled=true,
    materialized='table',
    tags=['national', 'marts']
  )
}}

/*
  Mart : qui préside chaque région, département et intercommunalité, et combien
  d'élus siègent à son conseil (2026-09-26, échelle des niveaux) — la ligne
  « Président : … · 57 élus » de leur page, comme « Maire : … » d'une commune.

  Source : raw_national.rne_executifs (RNE, trois fichiers). La collectivité est
  retrouvée par son SIREN, celui des pages de niveau :
    departement  code du département → le département OFGL de la dernière année
                 (« 6AE », la Collectivité européenne d'Alsace, est « 67A » à l'OFGL)
    region       code de la région → la région OFGL
    epci         le SIREN du fichier ; la Métropole de Lyon (intercommunalité et
                 département sous le même SIREN) y trouve son président.
  Non couvertes (autre fichier du RNE, « membres d'assemblée ») : Corse, Martinique,
  Guyane. Mesuré le 2026-09-26 : 18 intercommunalités sans conseil dans le fichier.

  Jamais de date de naissance, de sexe, de profession : le chargeur ne les lit pas.
*/

WITH elus AS (
    SELECT
        niveau,
        IF(niveau = 'departement' AND code = '6AE', '67A', code) AS code,
        libelle, nom, prenom, fonction,
        COALESCE(SAFE.PARSE_DATE('%Y-%m-%d', date_debut_fonction), SAFE.PARSE_DATE('%d/%m/%Y', date_debut_fonction)) AS debut_fonction
    FROM {{ source('national_raw', 'rne_executifs') }}
),

conseils AS (
    SELECT
        niveau, code,
        COUNT(*) AS n_elus,
        ARRAY_AGG(IF(STARTS_WITH(fonction, 'Président du conseil'), STRUCT(prenom, nom, fonction, debut_fonction), NULL)
                  IGNORE NULLS ORDER BY debut_fonction DESC LIMIT 1)[SAFE_OFFSET(0)] AS president
    FROM elus
    GROUP BY niveau, code
),

collectivites AS (
    SELECT niveau, siren, code
    FROM {{ ref('stg_ofgl_niveaux') }}
    WHERE TRUE
    QUALIFY annee = MAX(annee) OVER (PARTITION BY niveau)
        AND ROW_NUMBER() OVER (PARTITION BY niveau, siren ORDER BY annee DESC) = 1
)

SELECT
    c.niveau,
    c.siren,
    k.n_elus,
    k.president.prenom       AS president_prenom,
    k.president.nom          AS president_nom,
    k.president.fonction     AS president_fonction,
    k.president.debut_fonction AS president_depuis
FROM collectivites c
JOIN conseils k
  ON (c.niveau IN ('departement', 'region') AND k.niveau = c.niveau AND k.code = c.code)
  OR (c.niveau = 'epci' AND k.niveau = 'epci' AND k.code = c.siren)
  -- La Métropole de Lyon : son conseil est dans le fichier des conseils communautaires.
  OR (c.niveau = 'departement' AND k.niveau = 'epci' AND k.code = c.siren)
