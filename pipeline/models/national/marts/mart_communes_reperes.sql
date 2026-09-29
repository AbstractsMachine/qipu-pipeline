{{
  config(
    enabled=true,
    materialized='table',
    tags=['national', 'marts']
  )
}}

/*
  Mart : les repères de chaque commune (2026-09-23) — l'index national
  website/public/data/communes-all/index.json (export_communes_all.py).

  Sept agrégats OFGL par commune et par année, en montant et en euros par
  habitant, avec le nom, le département, la région, la population et le SIREN
  de l'année. C'est la base des comparaisons « communes de sa taille », du
  comparateur de deux communes et du simulateur.

  Remplace sync_ofgl_all_communes.py, qui téléchargeait l'OFGL à part, une
  année figée dans le code (2024) : ces agrégats sont déjà dans
  raw_national.ofgl_communes, rechargés par la chaîne annuelle quand l'OFGL
  publie. L'export choisit la dernière année complète.
*/

WITH ofgl AS (
    SELECT *
    FROM {{ ref('stg_ofgl_communes') }}
    WHERE agregat IN (
        'Dépenses totales hors remb',
        'Recettes totales hors emprunts',
        'Encours de dette',
        'Frais de personnel',
        'Impôts locaux',
        'Capacité ou besoin de financement',
        'Epargne brute'
    )
),

reperes AS (
SELECT
    annee,
    code_insee,
    ANY_VALUE(commune_nom)  AS commune_nom,
    ANY_VALUE(dep_name)     AS dep_name,
    ANY_VALUE(reg_name)     AS reg_name,
    MAX(population)         AS population,
    ANY_VALUE(siren)        AS siren,
    MAX(IF(agregat = 'Dépenses totales hors remb', montant, NULL))                  AS depenses_totales,
    MAX(IF(agregat = 'Dépenses totales hors remb', euros_par_habitant, NULL))       AS depenses_totales_hab,
    MAX(IF(agregat = 'Recettes totales hors emprunts', montant, NULL))              AS recettes_totales,
    MAX(IF(agregat = 'Recettes totales hors emprunts', euros_par_habitant, NULL))   AS recettes_totales_hab,
    MAX(IF(agregat = 'Encours de dette', montant, NULL))                            AS encours_dette,
    MAX(IF(agregat = 'Encours de dette', euros_par_habitant, NULL))                 AS encours_dette_hab,
    MAX(IF(agregat = 'Frais de personnel', montant, NULL))                          AS frais_personnel,
    MAX(IF(agregat = 'Frais de personnel', euros_par_habitant, NULL))               AS frais_personnel_hab,
    MAX(IF(agregat = 'Impôts locaux', montant, NULL))                               AS impots_locaux,
    MAX(IF(agregat = 'Impôts locaux', euros_par_habitant, NULL))                    AS impots_locaux_hab,
    MAX(IF(agregat = 'Capacité ou besoin de financement', montant, NULL))           AS capacite_financement,
    MAX(IF(agregat = 'Capacité ou besoin de financement', euros_par_habitant, NULL)) AS capacite_financement_hab,
    MAX(IF(agregat = 'Epargne brute', montant, NULL))                               AS epargne_brute,
    MAX(IF(agregat = 'Epargne brute', euros_par_habitant, NULL))                    AS epargne_brute_hab
FROM ofgl
GROUP BY annee, code_insee
),

-- Les dépenses du budget par nature (DGFiP), comptées comme le chiffre en tête
-- de la page commune (budget_sankey) : la médiane « des communes de sa taille »
-- se prend sur LA MÊME définition que le chiffre qu'elle accompagne. L'OFGL
-- (« Dépenses totales hors remb ») mesure autre chose — 1 387 € contre 1 447 €
-- à Draguignan en 2025 — et les mettre face à face comparait deux périmètres.
dgfip AS (
    SELECT annee, code_insee, SUM(montant_total) AS depenses
    FROM {{ ref('core_budget_national') }}
    WHERE sens_flux = 'Depense' AND montant_total > 0
    GROUP BY annee, code_insee
),

-- Les taxes foncières et d'habitation (compte 73111, 7311 en M14) : LA base des
-- impôts de la page commune (REGLES 8 de la maquette validée le 25/09) — la phrase,
-- le chiffre par habitant, la courbe et « D'où vient l'argent » disent le même
-- montant, et la médiane se prend sur lui. L'agrégat OFGL « Impôts locaux »
-- ajoute la TEOM et d'autres taxes : 33,1 M€ contre 30,95 à Draguignan en 2025.
foncier AS (
    SELECT annee, code_insee, SUM(montant) AS impots_73111
    FROM {{ ref('mart_budget_national_comptes') }}
    WHERE sens_flux = 'Recette' AND compte IN ('73111', '7311')
    GROUP BY annee, code_insee
),

-- Les dépenses d'équipement (comptes 20 hors 204, 21, 23) : le chiffre « … de dépenses
-- d'investissement » des communes sans présentation par politique (2026-09-26), pour que
-- sa médiane « des communes de sa taille » se prenne sur la même définition. Les
-- subventions d'équipement versées (204) sont dites à part sur la page.
equipement AS (
    SELECT annee, code_insee, SUM(montant) AS equipement
    FROM {{ ref('mart_budget_national_comptes') }}
    WHERE sens_flux = 'Depense'
      -- the page's own filter (lib/town-adapters/france.ts): the « équipement » group, 204 apart;
      -- by group, not by account prefix: small accounts are folded into « autres » in this mart.
      AND REGEXP_CONTAINS(LOWER(sankey_group_fr), r'équipement|equipement')
      AND NOT STARTS_WITH(compte, '204')
    GROUP BY annee, code_insee
)

SELECT
    r.*,
    d.depenses                                   AS depenses_dgfip,
    SAFE_DIVIDE(d.depenses, r.population)        AS depenses_dgfip_hab,
    f.impots_73111                               AS impots_73111,
    SAFE_DIVIDE(f.impots_73111, r.population)    AS impots_73111_hab,
    e.equipement                                 AS equipement_dgfip,
    SAFE_DIVIDE(e.equipement, r.population)      AS equipement_dgfip_hab
FROM reperes r
LEFT JOIN dgfip d USING (annee, code_insee)
LEFT JOIN foncier f USING (annee, code_insee)
LEFT JOIN equipement e USING (annee, code_insee)
