{#
  Balance DGFiP croisée nature × fonction → codes du budget voté par fonction
  de la Ville de Paris (M57). Le champ FONCTION de la DGFiP porte le préfixe
  de section (90 investissement, 93 fonctionnement) suivi de la sous-fonction,
  ou le code d'un chapitre non ventilé (921-923, 940-944).
  La règle reproduit tous les couples (fonction, chapitre) que la Ville a
  publiés en open data de 2019 à 2024 (vérifié le 28/09/2026).
  Utilisé par stg_budget_principal et par le test balance_budget_vs_ca_imprime.
#}
{% macro paris_dgfip_chapitre(fonction) -%}
    CASE
        WHEN LENGTH({{ fonction }}) = 3 AND LEFT({{ fonction }}, 2) IN ('92', '94') THEN {{ fonction }}
        WHEN SUBSTR({{ fonction }}, 3, 2) = '05' THEN CONCAT(LEFT({{ fonction }}, 2), '05')
        WHEN SUBSTR({{ fonction }}, 3, 2) IN ('43', '44') THEN CONCAT(LEFT({{ fonction }}, 2), SUBSTR({{ fonction }}, 3, 2))
        ELSE CONCAT(LEFT({{ fonction }}, 2), SUBSTR({{ fonction }}, 3, 1))
    END
{%- endmacro %}

{% macro paris_dgfip_fonction(fonction) -%}
    IF(LENGTH({{ fonction }}) = 3 AND LEFT({{ fonction }}, 2) IN ('92', '94'), '01', SUBSTR({{ fonction }}, 3))
{%- endmacro %}

{% macro paris_dgfip_section(compte) -%}
    IF(LEFT({{ compte }}, 1) IN ('6', '7'), 'Fonctionnement', 'Investissement')
{%- endmacro %}
