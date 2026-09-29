{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'marts']
  )
}}

/*
  Mart : le taux de logements sociaux SRU de chaque commune soumise à la loi,
  par inventaire. Lu par export_logement_sru.py (la part de Paris en tête de
  la page Logement, 2026-09-23).
*/

SELECT * FROM {{ ref('core_sru_inventaire') }}
