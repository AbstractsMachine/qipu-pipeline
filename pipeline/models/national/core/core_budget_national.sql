{{
  config(
    enabled=true,
    materialized='table',
    tags=['national', 'core']
  )
}}

/*
  Core: Budget National par nature (row-level OBT, une ligne par flux)

  Transforme les balances DGFiP (budget principal) en FLUX budgétaires signés,
  regroupés par nature (chapitre M14/M57 à 2 chiffres). Axe NATURE, pas fonction.

  Règles de sens (par classe/compte) :
    - Charges (classe 6, hors ordre)          → Dépense = obnetdeb
    - Produits (classe 7, hors ordre)         → Recette = obnetcre
    - Immobilisations (classe 2, équipement)  → Dépense = obnetdeb
    - Dotations & subv. invest. (10, 13)      → Recette = obnetcre
    - Emprunts (16) : DEUX flux
        nouveaux emprunts   → Recette = obnetcre
        remboursements      → Dépense = obnetdeb
    Opérations d'ordre (68/71/72/78/28/29, is_ordre) exclues : elles gonflent la
    balance sans être des flux réels → cohérent avec les agrégats OFGL "réels".

  Grain : (code_insee, siren, annee, section, sens_flux, sankey_group, category).
*/

WITH b AS (
    SELECT *
    FROM {{ ref('stg_dgfip_balances') }}
    WHERE section IN ('Fonctionnement', 'Investissement')
      AND is_ordre = FALSE
      -- Exclude the 3-digit "opérations d'ordre" that the 2-digit chapter can't
      -- catch: cessions d'immobilisations (675/676 en dépense, 775/776/777 en
      -- recette). Ils gonflent symétriquement les deux côtés sans être des flux
      -- réels — c'est la cause du biais +2,4 % vs le top-line OFGL "réel".
      AND LEFT(compte, 3) NOT IN ('675', '676', '775', '776', '777')
),

flows AS (
    -- ---- Dépenses (net débit) -------------------------------------------------
    -- montant NET par compte (débit − crédit) : nette les atténuations de charges
    -- (ex. 6419 remboursements sur rémunérations), comme le fait le top-line OFGL.
    SELECT
        annee, code_insee, siren, commune_nom, population, dep_name, reg_name,
        section,
        'Depense'        AS sens_flux,
        sankey_group_fr, sankey_group_en, category_fr, category_en,
        -- Emprunts (16) : garder le brut (remboursements) sur chaque face ;
        -- ailleurs : net débit − crédit.
        CASE WHEN nature_prefix = '16' THEN operations_nettes_debit
             ELSE operations_nettes_debit - operations_nettes_credit END AS montant
    FROM b
    WHERE (
            classe_compte = '6'
         OR (classe_compte = '2' AND nature_prefix IN ('20','21','22','23','24','26','27'))
         OR nature_prefix = '16'                       -- remboursement d'emprunts
      )

    UNION ALL

    -- ---- Recettes (net crédit) ------------------------------------------------
    -- montant NET par compte (crédit − débit) : nette les atténuations de produits
    -- (ex. 739 dégrèvements/reversements), comme le fait le top-line OFGL.
    SELECT
        annee, code_insee, siren, commune_nom, population, dep_name, reg_name,
        section,
        'Recette'        AS sens_flux,
        sankey_group_fr, sankey_group_en, category_fr, category_en,
        CASE WHEN nature_prefix = '16' THEN operations_nettes_credit
             ELSE operations_nettes_credit - operations_nettes_debit END AS montant
    FROM b
    WHERE (
            classe_compte = '7'
         OR nature_prefix IN ('10','13')               -- dotations & subv. d'invest.
         OR nature_prefix = '16'                        -- nouveaux emprunts
      )
)

SELECT
    code_insee,
    siren,
    ANY_VALUE(commune_nom)  AS commune_nom,
    ANY_VALUE(population)   AS population,
    ANY_VALUE(dep_name)     AS dep_name,
    ANY_VALUE(reg_name)     AS reg_name,
    annee,
    section,
    sens_flux,
    sankey_group_fr,
    sankey_group_en,
    category_fr,
    category_en,
    SUM(montant)            AS montant_total,
    COUNT(*)                AS nb_lignes
FROM flows
GROUP BY code_insee, siren, annee, section, sens_flux,
         sankey_group_fr, sankey_group_en, category_fr, category_en
