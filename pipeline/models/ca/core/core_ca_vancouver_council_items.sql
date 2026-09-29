-- =============================================================================
-- Core: COUNCIL ITEMS — one row per item voted on (item_key), the unit the
-- map's record panel lists. Tallies from the member-grain votes; the text is
-- the City's own agenda description (mojibake repaired where the placement
-- step repaired it); subjects are KEYWORD rules over that text, published
-- with the rules in themes.json — a tag says what the words say, nothing more.
--
--   outcome_line : "Carried unanimously" | "Carried 6–5" | "Lost 3–8"
--   title        : the description with its agenda numbering removed
--                  ("3. ", "RR5 - ", "Policy Report 2 - "), for display only
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core', 'citymap']) }}

WITH v AS (
    SELECT
        item_key,
        MIN(vote_date)                                  AS vote_date,
        ANY_VALUE(meeting_type)                         AS meeting_type,
        ANY_VALUE(meeting_id)                           AS meeting_id,
        ANY_VALUE(agenda_description)                   AS agenda_description,
        ANY_VALUE(decision)                             AS decision,
        COUNTIF(vote = 'In Favour')                     AS n_in_favour,
        COUNTIF(vote = 'In Opposition')                 AS n_opposition,
        COUNTIF(vote = 'Declared Conflict')             AS n_conflicts,
        COUNTIF(vote = 'Absent')                        AS n_absent,
        LOGICAL_OR(is_rezoning)                         AS is_rezoning
    FROM {{ ref('core_ca_vancouver_votes') }}
    GROUP BY item_key
),

rep AS (
    SELECT item_key, ANY_VALUE(agenda_description_repaired) AS text_repaired
    FROM {{ ref('stg_ca_vancouver_council_item_places') }}
    GROUP BY item_key
),

t AS (
    -- the export carries UTF-8 read as cp1252 on some rows ("â€“" for an en dash):
    -- the common sequences are mapped back here, for every item
    SELECT v.*,
        REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
            COALESCE(rep.text_repaired, v.agenda_description),
            'â€“', '–'), 'â€”', '—'), 'â€™', '’'), 'â€˜', '‘'), 'â€œ', '“'), 'â€', '”'), 'Ã©', 'é') AS text
    FROM v LEFT JOIN rep USING (item_key)
)

SELECT
    item_key,
    vote_date,
    EXTRACT(YEAR FROM vote_date) AS vote_year,
    meeting_type,
    meeting_id,
    text,
    TRIM(REGEXP_REPLACE(text,
        r'^\s*(?:(?:Policy|Administrative) Report \d+|Unfinished Business \d+|Motion on Notice [A-Z]?\.?\d*|Item \d+\s*(?:\([a-z]\))?|Comm\s*\d+|COMM\d+|(?:RR|R|A|B|NB|UB|P|CD)\s*-?\s*\d+[a-z]?|\d+[a-z]?)\s*[.:\-–]\s*', ''))
                                 AS title,
    decision,
    n_in_favour, n_opposition, n_conflicts, n_absent,
    CASE
        WHEN decision LIKE 'Carried Unanimously%' THEN 'Carried unanimously'
        WHEN n_in_favour + n_opposition > 0 THEN CONCAT(COALESCE(decision, 'Decided'), ' ', CAST(n_in_favour AS STRING), '–', CAST(n_opposition AS STRING))
        ELSE COALESCE(decision, 'Decided')
    END                          AS outcome_line,
    (n_in_favour > 0 AND n_opposition > 0) AS is_contested,
    is_rezoning,
    -- subjects: keyword rules over the City's own text (themes.json publishes them),
    -- shared with the 1970s minutes through the macro
    {{ ca_vancouver_subject_flags('text') }},
    CURRENT_TIMESTAMP() AS _built_at
FROM t
