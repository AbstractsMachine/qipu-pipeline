-- =============================================================================
-- Core: subventions Marseille rattachées à un lieu — ligne à ligne
--
-- Sources: core_marseille_subventions (une ligne par subvention, avec objet),
--          stg_marseille_place_subventions_rules (regex par lieu et relation).
-- Grain:   subvention × place_slug × relation.
--
-- operator  : le bénéficiaire EST le lieu (regex sur le nom du bénéficiaire).
-- residents : l'objet de la subvention nomme le lieu (regex sur objet, moins
--             l'exclusion écoles homonymes). L'objet est la preuve.
-- Les seuils de la règle (min_montant_total, max_rows) voyagent sur chaque
-- ligne ; c'est mart_marseille_place_money qui les applique (opérateur
-- dominant, liste des résidents plafonnée).
-- =============================================================================

{{ config(materialized='table', schema='analytics', tags=['core', 'marseille', 'lieux']) }}

WITH rules AS (
    SELECT * FROM {{ ref('stg_marseille_place_subventions_rules') }}
),

subs AS (
    SELECT annee, beneficiaire, objet, montant
    FROM {{ ref('core_marseille_subventions') }}
)

SELECT
    r.place_slug,
    r.relation,
    s.annee,
    s.beneficiaire,
    s.objet,
    s.montant,
    r.min_montant_total,
    r.max_rows
FROM subs s
JOIN rules r
  ON (r.relation = 'operator'
      AND REGEXP_CONTAINS(s.beneficiaire, r.match_regex))
  OR (r.relation = 'residents'
      AND s.objet IS NOT NULL
      AND REGEXP_CONTAINS(s.objet, r.match_regex)
      AND (r.exclude_regex IS NULL OR NOT REGEXP_CONTAINS(s.objet, r.exclude_regex)))
