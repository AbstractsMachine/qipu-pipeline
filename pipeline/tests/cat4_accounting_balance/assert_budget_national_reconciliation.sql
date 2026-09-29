/*
  Step-1 self-check (mandatory) — réconciliation budget national.

  Σ(détails balances DGFiP, fonctionnement réel) doit recoller au top-line OFGL
  `montant_bp` (budget principal, même périmètre que balances cbudg='1').

  Design : garde-fou de SANTÉ AGRÉGÉE, pas un seuil dur par commune. Sur 35 000
  communes hétérogènes (transitions M14→M57, restructurations budgétaires,
  budgets annexes), un seuil dur par ligne aura toujours une queue de cas
  atypiques légitimes. On teste donc l'identité au niveau POPULATION — le vrai
  self-check — et on échoue si un changement du pipeline la casse largement.

  État de référence (2023-2024, 15 442 communes matérielles) :
    médiane écart dépense = 0,0 %  ·  médiane écart recette = 0,0 %
    98,8 % dans ±5 % sur les DEUX faces.
  Le détail par commune vit dans mart_budget_reconciliation (inspection).

  Échoue si : < min_within des communes matérielles sont dans la tolérance,
  OU si la médiane d'écart dérive (> 1 %). Passe aujourd'hui ; attrape une
  régression de logique (mauvais compte, ordre non exclu, périmètre cbudg…).
*/

{% set tol = var('reconciliation_tol_pct', 0.05) %}
{% set min_within = var('reconciliation_min_within', 0.95) %}
{% set seuil = var('reconciliation_material_eur', 1000000) %}

WITH material AS (
    SELECT *
    FROM {{ ref('mart_budget_reconciliation') }}
    WHERE ofgl_dep_fonctionnement > {{ seuil }}
),

health AS (
    SELECT
        COUNT(*) AS n_material,
        AVG(CASE
              WHEN ABS(COALESCE(ecart_dep_pct, 1)) <= {{ tol }}
               AND ABS(COALESCE(ecart_rec_pct, 1)) <= {{ tol }}
              THEN 1 ELSE 0 END)                                    AS frac_within,
        ABS(APPROX_QUANTILES(ecart_dep_pct, 100)[OFFSET(50)])       AS abs_median_dep,
        ABS(APPROX_QUANTILES(ecart_rec_pct, 100)[OFFSET(50)])       AS abs_median_rec
    FROM material
)

SELECT *
FROM health
WHERE frac_within < {{ min_within }}
   OR abs_median_dep > 0.01
   OR abs_median_rec > 0.01
