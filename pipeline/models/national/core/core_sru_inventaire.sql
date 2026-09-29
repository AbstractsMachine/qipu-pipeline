{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'core']
  )
}}

/*
  Core : l'inventaire SRU tel que publié, un millésime par ligne (aucun calcul :
  les pages citent le taux officiel, elles ne le recalculent pas).
*/

SELECT * FROM {{ ref('stg_sru_inventaire') }}
