{#
  Les cellules fonction × compte d'une collectivité (2026-09-26) — le SQL de
  mart_communes_fonctions et de mart_communes_fonctions_complements, mis en
  macro pour servir tel quel aux communes (clé code_insee) et aux régions,
  départements, intercommunalités (clé siren, marts mart_niveaux_fonctions_*).
  Aucune différence de calcul entre les deux : c'est la condition pour que la
  page d'un département se lise comme celle d'une commune. Vérifié au
  découpage : les deux marts communes identiques à la ligne et au centime
  (3 486 875 et 526 295 lignes en dev).
#}

{% macro fonctions_cellules(categs, cle) %}
WITH lignes AS (
    SELECT
        annee,
        ligne,
        {{ cle }},
        libelle_budget,
        COALESCE(nomen, '?')                                AS nomen,
        IF(est_reversement, 'rev', fonction_cle)            AS compartiment,
        fonction_reference,
        compte,
        famille_nature,
        operations_nettes_debit                             AS montant
    FROM {{ ref('core_dgfip_nature_fonction') }}
    WHERE categ IN ({{ categs }})
      AND cbudg = '1'
      AND bal = 'DEF'
      AND classe_compte = '6'
      AND fonction_reference IS NOT NULL
      AND operations_nettes_debit != 0
      AND {{ cle }} IS NOT NULL
),

nomenclatures AS (
    SELECT annee, {{ cle }}, nomen AS nomenclature, libelle_budget
    FROM (
        SELECT annee, {{ cle }}, nomen, SUM(montant) AS montant, MIN(ligne) AS premiere_ligne,
               MIN(libelle_budget) AS libelle_budget
        FROM lignes
        GROUP BY annee, {{ cle }}, nomen
    )
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY annee, {{ cle }} ORDER BY montant DESC, premiere_ligne ASC
    ) = 1
),

cellules AS (
    SELECT
        annee,
        {{ cle }},
        compartiment,
        fonction_reference,
        compte,
        famille_nature,
        SUM(montant)   AS montant,
        MIN(ligne)     AS premiere_ligne,
        COUNT(*)       AS n_lignes
    FROM lignes
    GROUP BY annee, {{ cle }}, compartiment, fonction_reference, compte, famille_nature
)

SELECT
    c.annee,
    c.{{ cle }},
    n.libelle_budget,
    n.nomenclature,
    c.compartiment,
    c.fonction_reference,
    c.compte,
    c.famille_nature,
    c.montant,
    c.premiere_ligne,
    c.n_lignes
FROM cellules c
JOIN nomenclatures n USING (annee, {{ cle }})
{% endmacro %}

{% macro fonctions_complements(categs, cle, reelles=true) %}
WITH lignes AS (
    SELECT
        annee,
        ligne,
        {{ cle }},
        compte,
        IF(est_reversement, 'rev', fonction_cle) AS compartiment,
        fonction_reference,
        CASE
            -- 2324 (M57) = « Subventions d'équipements versées » en cours : de l'argent donné à
            -- d'autres, comme le 204, jamais les travaux de la collectivité (corrigé le
            -- 2026-09-26 : 42,9 M€ de 156 communes, 1,6 Md€ des départements, 2 Md€ des
            -- régions étaient comptés en « Ce qu'elle construit » ; l'OFGL les range en
            -- subventions d'équipement versées — Haute-Garonne 2025 : 33,1 + 83,6 = 116,7 M€).
            WHEN STARTS_WITH(compte, '204') OR STARTS_WITH(compte, '2324') THEN 'subv_equipement'
            WHEN classe_compte = '2'
                 AND SUBSTR(compte, 1, 2) IN ('20', '21', '23')
                THEN 'equipement'
            WHEN STARTS_WITH(compte, '64') THEN 'credit_64'
            WHEN STARTS_WITH(compte, '16')
                 AND NOT STARTS_WITH(compte, '165')
                 AND NOT STARTS_WITH(compte, '166')
                 AND NOT STARTS_WITH(compte, '16449')
                THEN 'remb_capital'
        END AS genre,
        operations_nettes_debit,
        operations_nettes_credit,
        operations_ordre_budgetaires_debit
    FROM {{ ref('core_dgfip_nature_fonction') }}
    WHERE categ IN ({{ categs }})
      AND cbudg = '1'
      AND bal = 'DEF'
      AND fonction_reference IS NOT NULL
      AND {{ cle }} IS NOT NULL
),

montants AS (
    SELECT
        annee,
        ligne,
        {{ cle }},
        compte,
        compartiment,
        fonction_reference,
        genre,
        -- Opérations RÉELLES seulement (REGLES 27) : le débit net moins les opérations d'ordre.
        -- Avant le 2026-09-26, débit − crédit : en M57, l'intégration des travaux terminés
        -- (23 → 21, écriture d'ordre) passe un crédit dans une fonction et un débit dans une
        -- autre — un « équipement » négatif en non ventilé, des listes par politique qui ne
        -- retombaient pas sur leur total. Vérifié contre l'OFGL (opérations réelles, budget
        -- principal) sur les 1 357 collectivités de niveau : écart médian 0,29 % contre 0,83 %.
        -- `reelles=false` : l'ancien calcul, gardé pour les COMMUNES tant que le total en tête
        -- de leur page (core_budget_national, débit − crédit, ordre compris) n'est pas passé
        -- aux opérations réelles — les deux doivent changer ensemble (bloc à part, 27/09).
        {% set moins = "operations_ordre_budgetaires_debit" if reelles else "operations_nettes_credit" %}
        CASE genre
            WHEN 'equipement'   THEN operations_nettes_debit - {{ moins }}
            WHEN 'subv_equipement' THEN operations_nettes_debit - {{ moins }}
            WHEN 'credit_64'    THEN operations_nettes_credit
            WHEN 'remb_capital' THEN operations_nettes_debit{{ " - operations_ordre_budgetaires_debit" if reelles else "" }}
        END AS montant
    FROM lignes
    WHERE genre IS NOT NULL
)

SELECT
    annee,
    {{ cle }},
    genre,
    compartiment,
    fonction_reference,
    compte,
    SUM(montant)  AS montant,
    MIN(ligne)    AS premiere_ligne
FROM montants
WHERE montant != 0
GROUP BY annee, {{ cle }}, genre, compartiment, fonction_reference, compte
{% endmacro %}
