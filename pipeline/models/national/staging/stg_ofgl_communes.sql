{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}

/*
  Staging: OFGL — base communes consolidée (format LONG)

  Une ligne = commune × année × agrégat. Deux rôles :
    1. Dimension commune universelle (siren, insee, nom, dép/rég, population).
       C'est l'UNIVERS des ~35 000 communes — PAS le seed_communes_cibles.
    2. Agrégats de réconciliation. `montant_bp` = budget principal seul, ce qui
       se réconcilie directement avec les balances DGFiP filtrées sur cbudg='1'.

  Source LONG ingérée par sync_ofgl_national.py.
*/

WITH raw AS (
    SELECT * FROM {{ source('national_raw', 'ofgl_communes') }}
    WHERE categ = 'Commune'
      -- Drop rows without a commune INSEE code (a handful of mislabeled EPCI
      -- carry categ='Commune' with a null com_code — not real communes).
      AND com_code IS NOT NULL
)

SELECT
    SAFE_CAST(exer AS INT64)                       AS annee,
    CAST(siren AS STRING)                          AS siren,
    -- INSEE : préserver les zéros de tête (dép 01-09) et les codes corses (2A/2B)
    CASE
        WHEN SAFE_CAST(com_code AS INT64) IS NOT NULL
            THEN LPAD(CAST(SAFE_CAST(com_code AS INT64) AS STRING), 5, '0')
        ELSE CAST(com_code AS STRING)
    END                                            AS code_insee,
    CAST(com_name AS STRING)                       AS commune_nom,
    CAST(dep_code AS STRING)                        AS dep_code,
    CAST(dep_name AS STRING)                        AS dep_name,
    CAST(reg_code AS STRING)                        AS reg_code,
    CAST(reg_name AS STRING)                        AS reg_name,
    CAST(tranche_population AS STRING)              AS tranche_population,
    SAFE_CAST(ptot AS INT64)                        AS population,
    CAST(agregat AS STRING)                         AS agregat,
    SAFE_CAST(montant AS FLOAT64)                   AS montant,
    SAFE_CAST(montant_bp AS FLOAT64)                AS montant_bp,     -- budget principal
    SAFE_CAST(montant_ba AS FLOAT64)                AS montant_ba,     -- budgets annexes
    SAFE_CAST(euros_par_habitant AS FLOAT64)        AS euros_par_habitant
FROM raw
WHERE SAFE_CAST(exer AS INT64) IS NOT NULL
