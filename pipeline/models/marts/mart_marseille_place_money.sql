-- =============================================================================
-- Mart: l'argent public rattaché à chaque lieu Marseille (opérateur + résidents)
--
-- Source: core_marseille_place_subventions (lignes rattachées + seuils de la règle).
-- Grain:   place_slug × relation × beneficiaire (+ ligne par année pour l'opérateur,
--          dans rows_par_annee).
--
-- operator  : le bénéficiaire dominant (plus gros cumul) parmi les lignes
--             « operator » du lieu, s'il dépasse min_montant_total.
-- residents : les autres bénéficiaires dont l'objet nomme le lieu, hors
--             l'opérateur, top max_rows par montant, avec la preuve (l'objet
--             de la plus grosse subvention).
-- Consommé par export_marseille_place_money.py → fr/marseille/places/_money.json.
-- =============================================================================

{{ config(materialized='table', schema='marts', tags=['mart', 'marseille', 'lieux']) }}

WITH lines AS (
    SELECT * FROM {{ ref('core_marseille_place_subventions') }}
),

operator_by_ben AS (
    SELECT
        place_slug,
        beneficiaire,
        SUM(montant)   AS montant_total,
        SUM(n)         AS nb_subventions,
        ARRAY_AGG(STRUCT(annee, montant) ORDER BY annee) AS rows_raw,
        ANY_VALUE(min_montant_total) AS min_montant_total
    FROM (
        SELECT place_slug, beneficiaire, annee, ROUND(SUM(montant), 2) AS montant, COUNT(*) AS n,
               ANY_VALUE(min_montant_total) AS min_montant_total
        FROM lines WHERE relation = 'operator'
        GROUP BY 1, 2, 3
    )
    GROUP BY 1, 2
),

operator AS (
    SELECT
        o.place_slug,
        'operator'          AS relation,
        o.beneficiaire,
        ROUND(o.montant_total, 2) AS montant_total,
        o.nb_subventions,
        o.rows_raw          AS rows_par_annee,
        CAST(NULL AS STRING) AS preuve,
        1                   AS rang
    FROM operator_by_ben o
    WHERE o.montant_total >= o.min_montant_total
    QUALIFY ROW_NUMBER() OVER (PARTITION BY o.place_slug ORDER BY o.montant_total DESC, o.beneficiaire) = 1
),

residents_by_ben AS (
    SELECT
        place_slug,
        beneficiaire,
        ROUND(SUM(montant), 2) AS montant_total,
        COUNT(*)               AS nb_subventions,
        ARRAY_AGG(objet ORDER BY montant DESC, objet LIMIT 1)[OFFSET(0)] AS preuve,
        ANY_VALUE(max_rows)    AS max_rows
    FROM lines
    WHERE relation = 'residents'
    GROUP BY 1, 2
    HAVING SUM(montant) > 0
),

residents AS (
    SELECT
        b.place_slug,
        'residents'         AS relation,
        b.beneficiaire,
        b.montant_total,
        b.nb_subventions,
        CAST(NULL AS ARRAY<STRUCT<annee INT64, montant FLOAT64>>) AS rows_par_annee,
        b.preuve,
        ROW_NUMBER() OVER (PARTITION BY b.place_slug ORDER BY b.montant_total DESC, b.beneficiaire) AS rang
    FROM residents_by_ben b
    LEFT JOIN operator o ON o.place_slug = b.place_slug
    WHERE o.beneficiaire IS NULL OR o.beneficiaire != b.beneficiaire
    QUALIFY rang <= b.max_rows
)

SELECT * FROM operator
UNION ALL
SELECT * FROM residents
