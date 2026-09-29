{{
  config(
    enabled=true,
    materialized='table',
    tags=['national', 'marts']
  )
}}

/*
  Mart: réconciliation budget national (self-check Step-1)

  Vérifie que Σ(détails balances DGFiP) recolle au top-line OFGL pour la même
  commune × année. On compare la SECTION FONCTIONNEMENT (l'identité la plus
  propre) : classe 6/7 réelles (hors ordre) vs OFGL `montant_bp` (budget
  principal, donc même périmètre que balances cbudg='1').

  L'investissement est plus sensible aux conventions de capitalisation ; il est
  exposé pour contexte mais la garantie de test porte sur le fonctionnement.

  Le test dbt (tests/assert_budget_national_reconciliation.sql) échoue si l'écart
  relatif dépasse la tolérance sur les communes matérielles.
*/

WITH bal AS (
    SELECT
        code_insee,
        siren,
        annee,
        SUM(CASE WHEN section = 'Fonctionnement' AND sens_flux = 'Depense'
                 THEN montant_total ELSE 0 END) AS bal_dep_fonctionnement,
        SUM(CASE WHEN section = 'Fonctionnement' AND sens_flux = 'Recette'
                 THEN montant_total ELSE 0 END) AS bal_rec_fonctionnement
    FROM {{ ref('core_budget_national') }}
    GROUP BY code_insee, siren, annee
),

ofgl AS (
    SELECT
        code_insee,
        siren,
        annee,
        MAX(CASE WHEN agregat = 'Dépenses de fonctionnement' THEN montant_bp END) AS ofgl_dep_fonctionnement,
        MAX(CASE WHEN agregat = 'Recettes de fonctionnement' THEN montant_bp END) AS ofgl_rec_fonctionnement,
        MAX(population) AS population
    FROM {{ ref('stg_ofgl_communes') }}
    GROUP BY code_insee, siren, annee
)

SELECT
    b.code_insee,
    b.siren,
    b.annee,
    o.population,

    b.bal_dep_fonctionnement,
    o.ofgl_dep_fonctionnement,
    b.bal_dep_fonctionnement - o.ofgl_dep_fonctionnement AS ecart_dep,
    SAFE_DIVIDE(b.bal_dep_fonctionnement - o.ofgl_dep_fonctionnement,
                o.ofgl_dep_fonctionnement)               AS ecart_dep_pct,

    b.bal_rec_fonctionnement,
    o.ofgl_rec_fonctionnement,
    b.bal_rec_fonctionnement - o.ofgl_rec_fonctionnement AS ecart_rec,
    SAFE_DIVIDE(b.bal_rec_fonctionnement - o.ofgl_rec_fonctionnement,
                o.ofgl_rec_fonctionnement)               AS ecart_rec_pct

FROM bal b
INNER JOIN ofgl o
    ON b.code_insee = o.code_insee AND b.siren = o.siren AND b.annee = o.annee
