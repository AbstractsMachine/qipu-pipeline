{{ config(tags=['accounting_balance']) }}
-- Une année de budget exécuté lue hors de l'open data de la Ville (balance
-- DGFiP, voir stg_budget_principal) doit retomber, chapitre par chapitre, sur
-- le total imprimé dans le compte administratif (seed_paris_ca_totaux_imprimes,
-- relevé par scripts/tools/extract_ca_totaux_chapitres.py).
--
-- Deux contrôles, à 1 € près par chapitre :
--   1. la balance DGFiP ramenée aux chapitres (macros paris_dgfip_*) = le total
--      imprimé ;
--   2. le staging ne s'en écarte que des cellules nettes négatives qu'il
--      écarte (même règle que l'open data : montant > 0) — l'écart est borné
--      par la somme des lignes négatives du chapitre.
WITH imprime AS (
    SELECT annee, section, sens_flux, chapitre_code, CAST(montant_imprime AS NUMERIC) AS montant_imprime
    FROM {{ ref('seed_paris_ca_totaux_imprimes') }}
),
dgfip AS (
    SELECT
        annee,
        fonction,
        compte,
        COALESCE(SAFE_CAST(REPLACE(obnetdeb, ',', '.') AS NUMERIC), 0)
          - COALESCE(SAFE_CAST(REPLACE(oobdeb, ',', '.') AS NUMERIC), 0) AS depense,
        COALESCE(SAFE_CAST(REPLACE(obnetcre, ',', '.') AS NUMERIC), 0)
          - COALESCE(SAFE_CAST(REPLACE(oobcre, ',', '.') AS NUMERIC), 0) AS recette
    FROM {{ source('national_raw', 'dgfip_balances_nature_fonction') }}
    WHERE categ = 'PARIS' AND cbudg = '1' AND siren = '217500016'
      AND fonction IS NOT NULL
      AND annee IN (SELECT DISTINCT annee FROM imprime)
),
flux AS (
    SELECT annee, fonction, compte, 'Dépense' AS sens_flux, depense AS montant FROM dgfip
    UNION ALL
    SELECT annee, fonction, compte, 'Recette', recette FROM dgfip
),
source_chap AS (
    SELECT
        annee,
        {{ paris_dgfip_section('compte') }} AS section,
        sens_flux,
        {{ paris_dgfip_chapitre('fonction') }} AS chapitre_code,
        SUM(montant) AS montant_source,
        SUM(IF(montant < 0, -montant, 0)) AS negatifs
    FROM flux
    GROUP BY 1, 2, 3, 4
),
pipeline AS (
    SELECT annee, section, sens_flux, chapitre_code, SUM(CAST(montant AS NUMERIC)) AS montant_pipeline
    FROM {{ ref('stg_budget_principal') }}
    WHERE annee IN (SELECT DISTINCT annee FROM imprime)
    GROUP BY 1, 2, 3, 4
)
SELECT
    i.annee, i.section, i.sens_flux, i.chapitre_code,
    i.montant_imprime,
    COALESCE(s.montant_source, 0) AS montant_source,
    COALESCE(p.montant_pipeline, 0) AS montant_pipeline,
    COALESCE(s.negatifs, 0) AS negatifs
FROM imprime i
LEFT JOIN source_chap s USING (annee, section, sens_flux, chapitre_code)
LEFT JOIN pipeline p USING (annee, section, sens_flux, chapitre_code)
WHERE ABS(COALESCE(s.montant_source, 0) - i.montant_imprime) > 1
   OR COALESCE(p.montant_pipeline, 0) - COALESCE(s.montant_source, 0) < -1
   OR COALESCE(p.montant_pipeline, 0) - COALESCE(s.montant_source, 0) > COALESCE(s.negatifs, 0) + 1
