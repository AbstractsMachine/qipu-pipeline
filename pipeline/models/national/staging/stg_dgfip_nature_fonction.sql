{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}

/*
  Staging: DGFiP balances « présentation croisée nature-fonction »

  Une ligne = une ligne du CSV publié : un budget (IDENT = SIRET, CBUDG) × une
  FONCTION × un COMPTE, pour un exercice. TOUTES les collectivités (communes,
  Paris, GFP, départements, régions, syndicats, EPL…) : aucune catégorie n'est
  écartée ici. Chargé tel quel, en texte, par sync_dgfip_nature_fonction.py.

  Ce que ce modèle fait, et seulement ça :
    - les montants passent de « 96971,23 » à NUMERIC (exact au centime : les
      sommes ne dérivent pas comme en flottant) ; illisible → 0, comme avant ;
    - code_insee : le code commune à 5 caractères, recomposé depuis NDEPT
      (département sur 3 caractères) et INSEE (rang dans le département) :
        « 075 » + « 056 » → « 75056 »   (métropole : on retire le zéro de tête)
        « 02A » + « 004 » → « 2A004 »   (Corse)
        « 101 » + « 101 » → « 97101 »   (outre-mer : 101-106 = 971-976, le rang
                                          porte déjà le chiffre du département)
      NULL quand la ligne n'a pas de rang communal (groupements, syndicats…).
  Les codes (fonction, compte, nomenclature) restent des chaînes intactes.
*/

WITH src AS (
    SELECT * FROM {{ source('national_raw', 'dgfip_balances_nature_fonction') }}
)

SELECT
    annee,
    ligne,
    source_fichier,

    categ,
    ident                                                   AS siret,
    siren,
    ndept,
    insee                                                   AS insee_rang,
    CASE
        WHEN ndept IS NULL OR insee IS NULL THEN NULL
        WHEN ndept IN ('02A', '02B')               THEN CONCAT(SUBSTR(ndept, 2), insee)
        WHEN REGEXP_CONTAINS(ndept, r'^1[0-9]{2}$') THEN CONCAT('97', insee)
        WHEN REGEXP_CONTAINS(ndept, r'^0[0-9]{2}$') THEN CONCAT(SUBSTR(ndept, 2), insee)
        ELSE CONCAT(ndept, insee)
    END                                                     AS code_insee,
    lbudg                                                   AS libelle_budget,
    cbudg,
    ctype,
    cstyp,
    nomen,
    cregi,
    cacti,
    secteur,
    finess,
    codbud1,
    modvthel,
    bal,

    fonction                                                AS fonction_code,
    compte,

    COALESCE(SAFE_CAST(REPLACE(bedeb,    ',', '.') AS NUMERIC), 0) AS balance_entree_debit,
    COALESCE(SAFE_CAST(REPLACE(becre,    ',', '.') AS NUMERIC), 0) AS balance_entree_credit,
    COALESCE(SAFE_CAST(REPLACE(obnetdeb, ',', '.') AS NUMERIC), 0) AS operations_nettes_debit,
    COALESCE(SAFE_CAST(REPLACE(obnetcre, ',', '.') AS NUMERIC), 0) AS operations_nettes_credit,
    COALESCE(SAFE_CAST(REPLACE(onbdeb,   ',', '.') AS NUMERIC), 0) AS operations_non_budgetaires_debit,
    COALESCE(SAFE_CAST(REPLACE(onbcre,   ',', '.') AS NUMERIC), 0) AS operations_non_budgetaires_credit,
    COALESCE(SAFE_CAST(REPLACE(oobdeb,   ',', '.') AS NUMERIC), 0) AS operations_ordre_budgetaires_debit,
    COALESCE(SAFE_CAST(REPLACE(oobcre,   ',', '.') AS NUMERIC), 0) AS operations_ordre_budgetaires_credit,
    COALESCE(SAFE_CAST(REPLACE(sd,       ',', '.') AS NUMERIC), 0) AS solde_debiteur,
    COALESCE(SAFE_CAST(REPLACE(sc,       ',', '.') AS NUMERIC), 0) AS solde_crediteur
FROM src
