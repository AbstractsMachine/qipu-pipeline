{{
  config(
    enabled=true,
    materialized='table',
    tags=['national', 'marts']
  )
}}
/*
  Mart: l'indice des prix, moyenne annuelle (les années complètes seulement,
  12 mois). La fiche « évolution » d'une commune en tire une phrase neutre :
  « les prix ont augmenté de X % entre 2019 et 2025 (Insee) ».
*/
SELECT
    annee,
    ROUND(AVG(indice), 3) AS indice_moyen,
    COUNT(*)              AS n_mois
FROM {{ ref('stg_insee_ipc') }}
GROUP BY annee
HAVING COUNT(*) = 12
