{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'marts']
  )
}}

/*
  Mart : les lignes du Budget général lues par export_national_etat.py
  (etat_lfi_<année>.json, page /etat).
*/

SELECT * FROM {{ ref('core_etat_plf') }}
