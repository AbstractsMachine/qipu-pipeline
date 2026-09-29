{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'marts']
  )
}}

/*
  Mart : les séries Eurostat lues par export_national_eurostat.py, qui refait
  les fichiers de /dette, /fiscalite, /budget et du simulateur.
*/

SELECT * FROM {{ ref('core_eurostat_series') }}
