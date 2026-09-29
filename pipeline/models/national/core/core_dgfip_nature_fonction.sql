{{
  config(
    enabled=true,
    materialized='table',
    partition_by={'field': 'annee', 'data_type': 'int64', 'range': {'start': 2010, 'end': 2051, 'interval': 1}},
    cluster_by=['categ', 'cbudg'],
    tags=['national', 'core']
  )
}}

/*
  Core: balances DGFiP nature × fonction (row-level, toutes collectivités)

  Grain : une ligne de la balance publiée — (annee, ligne) est unique. Même
  périmètre que le staging : toutes les catégories (categ), tous les budgets
  (cbudg), toutes les classes de compte. Les filtres d'usage (communes, budget
  principal, fonctionnement) appartiennent aux marts.

  Les règles de lecture, posées une fois, ligne par ligne :

   1. fonction_reference — la balance mélange deux écritures du même axe :
        vote par nature   : la référence nue — « 020 », « 212 », « 4212 »
        vote par fonction : « 9 » + chiffre de section + référence — « 93020 »
      Les deux premiers caractères d'un code en « 9 » se retirent (préfixes
      observés : 90 à 96). NULL si ce qui reste ne commence pas par un chiffre.

   2. fonction_principale / fonction_cle — LA RUBRIQUE 01 N'EST PAS LA
      FONCTION 0. « 01 », « 010 »…« 019 » sont les « opérations non
      ventilables » (dette, fiscalité, opérations générales) : clé « nv ».
      Sinon, le premier chiffre. Les clés sont NEUTRES : « f4 » vaut « santé et
      action sociale » en M57 et « sport et jeunesse » en M14 ; le libellé se
      choisit à l'export d'après la nomenclature de la collectivité.

   3. est_reversement — comptes 6554 et 6556 : de l'argent encaissé puis
      transmis à une autre collectivité, pas une politique rendue. Le drapeau
      est posé ici ; c'est le mart qui en fait un compartiment propre.

   4. famille_nature — la seconde lecture du budget (« sous quelle forme
      l'argent sort »), selon les préfixes officiels de la classe 6 : c'est la
      structure des chapitres M57 (011 = 60-62, 012 = 64, 65, 66…). NULL hors de
      ces préfixes (classe 6 « 69 », autres classes).
*/

WITH lignes AS (
    SELECT
        *,
        CASE
            WHEN fonction_code IS NULL THEN NULL
            WHEN STARTS_WITH(fonction_code, '9') THEN SUBSTR(fonction_code, 3)
            ELSE fonction_code
        END AS fonction_ref_brute
    FROM {{ ref('stg_dgfip_nature_fonction') }}
),

references AS (
    SELECT
        *,
        IF(REGEXP_CONTAINS(fonction_ref_brute, r'^[0-9]'), fonction_ref_brute, NULL) AS fonction_reference
    FROM lignes
),

principales AS (
    SELECT
        *,
        CASE
            WHEN fonction_reference IS NULL THEN NULL
            WHEN SUBSTR(fonction_reference, 1, 2) = '01' THEN 'nv'
            ELSE SUBSTR(fonction_reference, 1, 1)
        END AS fonction_principale
    FROM references
)

SELECT
    annee,
    ligne,
    source_fichier,

    categ,
    siret,
    siren,
    ndept,
    insee_rang,
    code_insee,
    libelle_budget,
    cbudg,
    ctype,
    cstyp,
    nomen,
    bal,

    fonction_code,
    fonction_reference,
    fonction_principale,
    CASE fonction_principale
        WHEN 'nv' THEN 'nv'
        WHEN '0'  THEN 'f0_services_generaux'
        WHEN '1'  THEN 'f1_securite'
        WHEN '2'  THEN 'f2_enseignement'
        WHEN '3'  THEN 'f3_culture'
        WHEN '4'  THEN 'f4'
        WHEN '5'  THEN 'f5'
        WHEN '6'  THEN 'f6'
        WHEN '7'  THEN 'f7'
        WHEN '8'  THEN 'f8'
        WHEN '9'  THEN 'f9_action_eco'
    END                                                        AS fonction_cle,

    compte,
    SUBSTR(compte, 1, 1)                                       AS classe_compte,
    CASE SUBSTR(compte, 1, 2)
        WHEN '60' THEN 'achats'
        WHEN '61' THEN 'achats'
        WHEN '62' THEN 'achats'
        WHEN '63' THEN 'impots'
        WHEN '64' THEN 'salaires'
        WHEN '65' THEN 'gestion'
        WHEN '66' THEN 'dette'
        WHEN '67' THEN 'exceptionnel'
        WHEN '68' THEN 'dotations'
    END                                                        AS famille_nature,
    COALESCE(STARTS_WITH(compte, '6554') OR STARTS_WITH(compte, '6556'), FALSE) AS est_reversement,

    balance_entree_debit,
    balance_entree_credit,
    operations_nettes_debit,
    operations_nettes_credit,
    operations_non_budgetaires_debit,
    operations_non_budgetaires_credit,
    operations_ordre_budgetaires_debit,
    operations_ordre_budgetaires_credit,
    solde_debiteur,
    solde_crediteur
FROM principales
