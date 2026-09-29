-- =============================================================================
-- Staging: DRIHL — file d'attente logement social Paris (dernière année publiée)
--
-- Source: raw_national.drihl_paris (sync_drihl_paris.py, toutes les années
--   publiées par la DRIHL, rechargées quand un classeur nouveau paraît).
--   Tant que cette table n'existe pas (avant le premier passage de la chaîne
--   annuelle), le seed de 2024 d'origine : le refresh de Paris du lundi ne
--   doit jamais tomber sur une source absente.
-- Grain: code_insee pour la DERNIÈRE année (75 + 75056 + 75101..75120) —
--   core_logement_attente_arr classe les arrondissements et l'export prend
--   « le » total Paris : une seule année en aval, les autres restent en raw.
-- =============================================================================

{{ config(materialized='view', schema='staging', tags=['staging','logement']) }}

-- depends_on: {{ source('national_raw', 'drihl_paris') }}
{% set raw_rel = adapter.get_relation(database='open-data-france-484717', schema='raw_national', identifier='drihl_paris') %}

WITH src AS (
{% if raw_rel is not none %}
    SELECT
        CAST(code_insee AS STRING)                      AS code_insee,
        CAST(nom AS STRING)                             AS nom,
        CAST(niveau_geo AS STRING)                      AS niveau_geo,
        SAFE_CAST(annee AS INT64)                       AS annee,
        SAFE_CAST(demandes_choix1 AS INT64)             AS demandes_choix1,
        SAFE_CAST(attributions AS INT64)                AS attributions,
        SAFE_CAST(ratio_dem_attrib AS FLOAT64)          AS ratio_dem_attrib,
        SAFE_CAST(delai_median_attribution_mois AS FLOAT64) AS delai_median_attribution_mois,
        SAFE_CAST(part_anciennete_5ans_plus AS FLOAT64) AS part_anciennete_5ans_plus,
        CAST(source AS STRING)                          AS source,
        CAST(source_url AS STRING)                      AS source_url
    FROM {{ source('national_raw', 'drihl_paris') }}
{% else %}
    SELECT * FROM {{ ref('seed_drihl_paris_2024') }}
{% endif %}
)

SELECT * FROM src
WHERE annee = (SELECT MAX(annee) FROM src)
