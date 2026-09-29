{#
  The subjects of a council text: KEYWORD rules over the City's own words,
  published with the rules in the map's themes.json. One macro for the voting
  record (2016→) and the 1970s minutes, so a subject means the same words in
  both. A flag says what the words say, nothing more.
#}
{% macro ca_vancouver_subject_flags(text) %}
    (REGEXP_CONTAINS(LOWER({{ text }}), r'rezon|cd-1|text amendment|official development plan|\bodp\b|zoning')) AS s_rezoning,
    (REGEXP_CONTAINS(LOWER({{ text }}), r'housing|rental|tenant|renovict|affordab|shelter|modular|homeless')) AS s_housing,
    (REGEXP_CONTAINS(LOWER({{ text }}), r'heritage')) AS s_heritage,
    (REGEXP_CONTAINS(LOWER({{ text }}), r'liquor|licen[cs]e|patio|cannabis|brewery|lounge')) AS s_licences,
    (REGEXP_CONTAINS(LOWER({{ text }}), r'closure and sale|lane|road closure|sale of|lease|acquisition|easement|encroachment')) AS s_land
{% endmacro %}
