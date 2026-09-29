{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'core']
  )
}}

/*
  Core : les séries Eurostat des pages nationales, telles que publiées (aucun
  calcul : les pages rapportent Eurostat, elles ne le recalculent pas).
*/

SELECT * FROM {{ ref('stg_eurostat_series') }}
