{{
  config(
    enabled=true,
    materialized='table',
    cluster_by=['code_insee'],
    tags=['national', 'marts']
  )
}}

/*
  Mart: détail des comptes derrière chaque ligne du budget par nature.

  Une ligne = (commune × année × sens × groupe sankey × compte). Mêmes règles de
  sens et de périmètre que core_budget_national (budget principal, hors
  opérations d'ordre, hors cessions), au compte complet au lieu du chapitre.

  Montants arrondis au centime (la balance DGFiP est tenue au centime) : en
  FLOAT64, « total du groupe − somme des comptes gardés » laissait des restes
  de 1e-10 € qui créaient une ligne « Autres » fantôme selon l'ordre des sommes.

  Libellés en français simple : seed_comptes_libelles_simples (≈230 comptes).
  On ne garde que les comptes traduits qui pèsent au moins 1 % de leur groupe ;
  le reste du groupe devient une ligne « Autres » (compte = 'autres'), pour que
  la somme des lignes reste égale au total du groupe affiché.
*/

WITH b AS (
    SELECT *
    FROM {{ ref('stg_dgfip_balances') }}
    WHERE section IN ('Fonctionnement', 'Investissement')
      AND is_ordre = FALSE
      AND LEFT(compte, 3) NOT IN ('675', '676', '775', '776', '777')
),

flows AS (
    SELECT
        annee, code_insee, sankey_group_fr, compte,
        'Depense' AS sens_flux,
        CASE WHEN nature_prefix = '16' THEN operations_nettes_debit
             ELSE operations_nettes_debit - operations_nettes_credit END AS montant
    FROM b
    WHERE classe_compte = '6'
       OR (classe_compte = '2' AND nature_prefix IN ('20','21','22','23','24','26','27'))
       OR nature_prefix = '16'

    UNION ALL

    SELECT
        annee, code_insee, sankey_group_fr, compte,
        'Recette' AS sens_flux,
        CASE WHEN nature_prefix = '16' THEN operations_nettes_credit
             ELSE operations_nettes_credit - operations_nettes_debit END AS montant
    FROM b
    WHERE classe_compte = '7'
       OR nature_prefix IN ('10','13')
       OR nature_prefix = '16'
),

par_compte AS (
    SELECT annee, code_insee, sens_flux, sankey_group_fr, compte, ROUND(SUM(montant), 2) AS montant
    FROM flows
    WHERE sankey_group_fr IS NOT NULL
    GROUP BY 1, 2, 3, 4, 5
    HAVING montant > 0
),

totaux AS (
    SELECT annee, code_insee, sens_flux, sankey_group_fr, ROUND(SUM(montant), 2) AS total_groupe
    FROM par_compte
    GROUP BY 1, 2, 3, 4
),

libelles AS (
    SELECT CAST(compte AS STRING) AS compte, libelle_fr, libelle_en
    FROM {{ ref('seed_comptes_libelles_simples') }}
),

gardes AS (
    SELECT
        p.annee, p.code_insee, p.sens_flux, p.sankey_group_fr,
        p.compte, l.libelle_fr, l.libelle_en, p.montant, t.total_groupe
    FROM par_compte p
    JOIN totaux t USING (annee, code_insee, sens_flux, sankey_group_fr)
    JOIN libelles l ON l.compte = p.compte
    WHERE p.montant >= 0.01 * t.total_groupe
),

autres AS (
    SELECT
        t.annee, t.code_insee, t.sens_flux, t.sankey_group_fr,
        'autres' AS compte, 'Autres' AS libelle_fr, 'Other' AS libelle_en,
        ROUND(t.total_groupe - COALESCE(SUM(g.montant), 0), 2) AS montant, t.total_groupe
    FROM totaux t
    LEFT JOIN gardes g USING (annee, code_insee, sens_flux, sankey_group_fr)
    GROUP BY 1, 2, 3, 4, t.total_groupe
    HAVING ROUND(t.total_groupe - COALESCE(SUM(g.montant), 0), 2) > 0
)

SELECT * FROM gardes
UNION ALL
SELECT * FROM autres
