{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'core']
  )
}}

/*
  Core : le Budget général (BG) de l'État, ligne à ligne. Les comptes spéciaux
  et les budgets annexes restent hors du périmètre de la page /etat.
*/

SELECT * FROM {{ ref('stg_etat_plf') }}
WHERE typebudget = 'BG'
