{{
  config(
    enabled=true,
    materialized='table',
    cluster_by=['code_insee'],
    tags=['national', 'marts']
  )
}}
/*
  Mart: les subventions nominatives de chaque commune, par bénéficiaire
  (2026-09-25) — l'onglet « Ses subventions » de la page commune. Les lignes
  d'un même nom sont additionnées (régularisations comprises) ; un bénéficiaire
  dont le total en argent est nul et qui n'a reçu qu'une aide en nature garde
  sa ligne, avec son aide décrite.
*/
SELECT
    code_insee,
    ANY_VALUE(doc_type)                           AS doc_type,
    ANY_VALUE(annee)                              AS annee,
    ANY_VALUE(source_url)                         AS source_url,
    nom,
    ROUND(SUM(montant), 2)                        AS montant,
    COUNT(*)                                      AS n_lignes,
    STRING_AGG(DISTINCT aide_nature, ' ; ' LIMIT 3) AS aide_nature,
    ANY_VALUE(type_beneficiaire)                  AS type_beneficiaire,
    MIN(rang)                                     AS premier_rang
FROM {{ ref('core_subventions_nominatives') }}
GROUP BY code_insee, nom
