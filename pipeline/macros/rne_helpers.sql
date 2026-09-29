{#
  =============================================================================
  Répertoire national des élus — aides partagées par les modèles national/.
  =============================================================================
#}

{# Nom ou prénom d'élu ramené à une forme comparable d'une version du
   répertoire à l'autre : majuscules, sans accents, espaces et tirets réduits
   à une espace. « Jean-Pierre » = « JEAN PIERRE », « Éric » = « ERIC ». Sert
   à dire « même personne » entre deux captures (mart_maires_national). #}
{% macro rne_nom_norm(col) -%}
  TRIM(REGEXP_REPLACE(REGEXP_REPLACE(NORMALIZE(UPPER(IFNULL({{ col }}, '')), NFD), r'\pM', ''), r'[\s\-]+', ' '))
{%- endmacro %}
