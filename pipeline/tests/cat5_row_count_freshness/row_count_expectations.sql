{{ config(tags=['row_count']) }}
{# Plafonds et planchers de row count par core. Si la donnée brute est
   re-syncée et qu'un sync casse partiellement, on s'attend à voir le
   row count chuter en dehors du range — ce test flag immédiatement.

   Les ranges sont volontairement larges (×3) pour absorber les
   évolutions naturelles ; resserrer si on a besoin de plus de
   sensibilité (avec le risque de faux positifs).

   core_dette_garantie est contrôlé par exercice, pas en total : son grain
   est emprunt × année de publication, donc le total grossit à chaque
   exercice ingéré. Le plafond total 30k–80k datait d'un sync figé à six
   exercices ; le passage à 2007→2025 (5fc42ef1f, 141 381 lignes) l'a fait
   tomber le 2026-09-14 sans qu'aucune donnée soit fausse. Et en total, un
   exercice entier perdu (~10 000 lignes) passait sous le plancher sans
   bruit. Par exercice : 5 043 à 10 347 lignes observées de 2007 à 2025. #}

WITH expectations AS (
    SELECT * FROM UNNEST([
        STRUCT('core_budget'                AS model, 15000 AS min_n,  80000 AS max_n),
        STRUCT('core_budget_vote'           AS model, 10000 AS min_n,  50000 AS max_n),
        -- core_subventions : 72 722 lignes 2010-2024, 78 240 avec 2025 (5 518) ;
        -- chaque exercice ajoute 5-7 k lignes, le plafond suit.
        STRUCT('core_subventions'           AS model, 30000 AS min_n, 100000 AS max_n),
        STRUCT('core_ap_projets'            AS model,  3000 AS min_n,  15000 AS max_n),
        STRUCT('core_marches_publics'       AS model, 10000 AS min_n,  30000 AS max_n),
        STRUCT('core_logements_sociaux'     AS model,  3000 AS min_n,  10000 AS max_n),
        STRUCT('core_deliberations'         AS model,  8000 AS min_n,  50000 AS max_n)
    ])
),
actual AS (
    SELECT 'core_budget' AS model, COUNT(*) AS n FROM {{ ref('core_budget') }}
    UNION ALL SELECT 'core_budget_vote', COUNT(*) FROM {{ ref('core_budget_vote') }}
    UNION ALL SELECT 'core_subventions', COUNT(*) FROM {{ ref('core_subventions') }}
    UNION ALL SELECT 'core_ap_projets', COUNT(*) FROM {{ ref('core_ap_projets') }}
    UNION ALL SELECT 'core_marches_publics', COUNT(*) FROM {{ ref('core_marches_publics') }}
    UNION ALL SELECT 'core_logements_sociaux', COUNT(*) FROM {{ ref('core_logements_sociaux') }}
    UNION ALL SELECT 'core_deliberations', COUNT(*) FROM {{ ref('core_deliberations') }}
),
dette_par_exercice AS (
    SELECT annee, COUNT(*) AS n
    FROM {{ ref('core_dette_garantie') }}
    GROUP BY annee
)
SELECT a.model, a.n AS actual_count, e.min_n, e.max_n,
       CASE
         WHEN a.n < e.min_n THEN 'below_min'
         WHEN a.n > e.max_n THEN 'above_max'
       END AS status
FROM actual a
JOIN expectations e USING (model)
WHERE a.n < e.min_n OR a.n > e.max_n

UNION ALL

-- Un exercice tronqué ou gonflé
SELECT CONCAT('core_dette_garantie · ', CAST(annee AS STRING)), n, 2500, 30000,
       IF(n < 2500, 'below_min', 'above_max')
FROM dette_par_exercice
WHERE n < 2500 OR n > 30000

UNION ALL

-- Un exercice absent au milieu de la série
SELECT 'core_dette_garantie · exercices', COUNT(*),
       MAX(annee) - MIN(annee) + 1, MAX(annee) - MIN(annee) + 1,
       'exercice_manquant'
FROM dette_par_exercice
HAVING COUNT(*) < MAX(annee) - MIN(annee) + 1
