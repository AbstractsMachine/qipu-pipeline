{{
  config(
    enabled=true,
    materialized='table',
    partition_by={'field': 'annee', 'data_type': 'int64', 'range': {'start': 2010, 'end': 2051, 'interval': 1}},
    cluster_by=['siren'],
    tags=['national', 'marts']
  )
}}

/*
  Mart : mart_communes_fonctions, pour les régions (REG, CTU), les départements (DEPT, ML) et les
  intercommunalités (GFP, EPT) — clé siren (2026-09-26, échelle des niveaux).
  Même macro, même calcul que pour les communes (macros/fonctions_cellules.sql) :
  export_territoires.py les passe à la même construction que export_communes_fonctions.py.
*/

{{ fonctions_cellules("'REG', 'CTU', 'DEPT', 'ML', 'GFP', 'EPT'", 'siren') }}
