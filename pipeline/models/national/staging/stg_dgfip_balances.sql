{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}

/*
  Staging: DGFiP Balances Comptables (national, ungated)

  Une ligne = 1 compte (article) du BUDGET PRINCIPAL (cbudg='1') d'une commune,
  pour une année. Le filtre cbudg='1' + categ='Commune' est appliqué à l'INGEST
  (sync_dgfip_balances_national.py) : toutes les communes, aucune restriction par
  seed_communes_cibles.

  Nomenclatures M14 et M57 (+ variantes abrégées M14A/M57A) traitées ensemble :
  au niveau du compte à 2 chiffres, la sémantique de classe est partagée
    classe 6 = charges · 7 = produits · 2 = immobilisations · 1 = capitaux/dette.

  La dimension commune (insee, nom, dép, rég, population) vient d'OFGL, jointe par
  SIREN — c'est l'univers national, pas un seed. Le slug est attaché à l'export
  (parité avec communes-all/index.json), pas ici.
*/

WITH balances AS (
    SELECT
        SAFE_CAST(exer AS INT64)                    AS annee,
        CAST(siren AS STRING)                       AS siren,
        CAST(nomen AS STRING)                       AS nomen,
        CAST(compte AS STRING)                      AS compte,
        LEFT(CAST(compte AS STRING), 2)             AS nature_prefix,
        LEFT(CAST(compte AS STRING), 1)             AS classe_compte,
        COALESCE(SAFE_CAST(obnetdeb AS FLOAT64), 0) AS operations_nettes_debit,
        COALESCE(SAFE_CAST(obnetcre AS FLOAT64), 0) AS operations_nettes_credit
    FROM {{ source('national_raw', 'dgfip_balances') }}
    WHERE compte IS NOT NULL
),

-- Dimension commune universelle (une ligne par commune × année) depuis OFGL.
commune_dim AS (
    SELECT DISTINCT
        annee,
        siren,
        code_insee,
        commune_nom,
        dep_code,
        dep_name,
        reg_code,
        reg_name,
        population
    FROM {{ ref('stg_ofgl_communes') }}
),

nomenclature AS (
    SELECT * FROM {{ ref('seed_nomenclature_comptes') }}
)

SELECT
    b.annee,
    b.siren,
    d.code_insee,
    d.commune_nom,
    d.dep_code,
    d.dep_name,
    d.reg_code,
    d.reg_name,
    d.population,

    b.nomen,
    b.compte,
    b.nature_prefix,
    b.classe_compte,
    b.operations_nettes_debit,
    b.operations_nettes_credit,

    -- Nomenclature (M14/M57, par nature). Non mappé → NULL (classes 3/4/5 de bilan,
    -- exclues plus bas dans core par le filtre de section).
    n.section,
    n.default_sens,
    COALESCE(n.is_ordre, FALSE)                          AS is_ordre,
    n.sankey_group_fr,
    n.sankey_group_en,
    n.category_fr,
    n.category_en

FROM balances b
INNER JOIN commune_dim d
    ON b.siren = d.siren AND b.annee = d.annee
LEFT JOIN nomenclature n
    ON b.nature_prefix = n.nature_prefix
