{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}

/*
  Staging : OFGL — les collectivités au-dessus de la commune, en une forme
  (2026-09-26, échelle des niveaux).

  Une ligne = collectivité × exercice × agrégat, pour trois niveaux :
    region       ofgl_regions       régions (REG) et collectivités uniques (CTU :
                                    Corse, Martinique, Guyane), 2012→
    departement  ofgl_departements  départements (DEPT), Métropole de Lyon (ML),
                                    Paris (PARIS), 2012→
    epci         ofgl_gfp           intercommunalités à fiscalité propre (CC, CA,
                                    CU, M, EPT, MET69, MET75), 2018→

  `code` est l'identifiant lisible du niveau (code région, code département) ;
  pour une intercommunalité, son SIREN. `type` : la catégorie OFGL (région,
  département) ou la nature juridique (intercommunalité). `tranche` et
  `statut` : les strates OFGL qui servent aux comparaisons « de sa taille »
  (statut urbain/rural : départements seulement).

  Montants : `montant` = consolidé (budget principal + budgets annexes, flux
  croisés retirés), `montant_bp` = budget principal seul (celui qui se
  réconcilie avec les balances DGFiP cbudg = 1).
*/

WITH regions AS (
    SELECT
        'region'                          AS niveau,
        exer, siren, categ,
        reg_code                          AS code,
        reg_name                          AS nom,
        CAST(NULL AS STRING)              AS dep_code,
        CAST(NULL AS STRING)              AS dep_name,
        reg_code, reg_name,
        categ                             AS type,
        CAST(NULL AS STRING)              AS tranche,
        CAST(NULL AS STRING)              AS statut,
        outre_mer, agregat, montant, montant_bp, montant_ba, montant_flux, ptot, euros_par_habitant
    FROM {{ source('national_raw', 'ofgl_regions') }}
),

departements AS (
    SELECT
        'departement', exer, siren, categ,
        dep_code, dep_name,
        dep_code, dep_name,
        reg_code, reg_name,
        categ,
        dep_tranche_population,
        dep_status,
        outre_mer, agregat, montant, montant_bp, montant_ba, montant_flux, ptot, euros_par_habitant
    FROM {{ source('national_raw', 'ofgl_departements') }}
),

epci AS (
    SELECT
        'epci', exer, siren, categ,
        -- Quelques intercommunalités n'ont pas de nom en 2018-2021 : le libellé du budget.
        siren, COALESCE(epci_name, lbudg),
        dep_code, dep_name,
        reg_code, reg_name,
        nat_juridique,
        gfp_tranche_population,
        CAST(NULL AS STRING),
        outre_mer, agregat, montant, montant_bp, montant_ba, montant_flux, ptot, euros_par_habitant
    FROM {{ source('national_raw', 'ofgl_gfp') }}
),

unis AS (
    SELECT * FROM regions
    UNION ALL SELECT * FROM departements
    UNION ALL SELECT * FROM epci
)

SELECT
    niveau,
    SAFE_CAST(exer AS INT64)             AS annee,
    CAST(siren AS STRING)                AS siren,
    CAST(code AS STRING)                 AS code,
    CAST(nom AS STRING)                  AS nom,
    CAST(type AS STRING)                 AS type,
    CAST(categ AS STRING)                AS categ,
    CAST(dep_code AS STRING)             AS dep_code,
    CAST(dep_name AS STRING)             AS dep_name,
    CAST(reg_code AS STRING)             AS reg_code,
    CAST(reg_name AS STRING)             AS reg_name,
    CAST(tranche AS STRING)              AS tranche,
    CAST(statut AS STRING)               AS statut,
    CAST(outre_mer AS STRING)            AS outre_mer,
    CAST(agregat AS STRING)              AS agregat,
    SAFE_CAST(montant AS FLOAT64)        AS montant,
    SAFE_CAST(montant_bp AS FLOAT64)     AS montant_bp,
    SAFE_CAST(montant_ba AS FLOAT64)     AS montant_ba,
    SAFE_CAST(montant_flux AS FLOAT64)   AS montant_flux,
    SAFE_CAST(ptot AS FLOAT64)           AS population,
    SAFE_CAST(euros_par_habitant AS FLOAT64) AS euros_par_habitant
FROM unis
WHERE agregat IS NOT NULL AND siren IS NOT NULL
