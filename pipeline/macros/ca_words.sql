{#
  A name reduced to its words, for the landmark rules (seed_ca_vancouver_landmarks):
  lower case, every run of characters that is not a letter or a digit becomes
  one space, and a space on each side. A rule `p` then matches WHOLE WORDS
  only as ' (p) ' — "ile" can never match inside "file", "qet" never inside a
  longer word, and "Kitsilano & Kerrisdale Arena" reads "kitsilano kerrisdale
  arena" (BigQuery's RE2 has no look-around, so \b cannot see past "&").
#}
{% macro ca_words(expr) -%}
CONCAT(' ', TRIM(REGEXP_REPLACE(LOWER({{ expr }}), r'[^a-z0-9]+', ' ')), ' ')
{%- endmacro %}

{% macro ca_word_rule(rule) -%}
CONCAT(' (', {{ rule }}, ') ')
{%- endmacro %}

{#- The same rule without capturing groups, for REGEXP_INSTR (which refuses
    more than one): where in the name the rule first matches. -#}
{% macro ca_word_rule_at(rule) -%}
CONCAT(' (?:', REPLACE({{ rule }}, '(', '(?:'), ') ')
{%- endmacro %}
