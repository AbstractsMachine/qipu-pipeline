-- =============================================================================
-- Mart: the most contested council items — one row per item, ranked by
-- members voting In Opposition. Names of MEMBERS (elected officials, public
-- record) are not carried here; the item, the tally and the outcome are.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH cat AS (
    SELECT dataset_title, dataset_page_url, license_title, rows_updated_at
    FROM {{ ref('core_ca_vancouver_source_catalog') }}
    WHERE source_id = 'council_voting_records'
),

items AS (
    SELECT
        item_key,
        ANY_VALUE(agenda_description)  AS agenda_description,
        ANY_VALUE(meeting_type)        AS meeting_type,
        MIN(vote_date)                 AS vote_date,
        ANY_VALUE(decision)            AS decision,
        COUNTIF(vote = 'In Favour')    AS n_in_favour,
        COUNTIF(is_opposition)         AS n_opposition,
        COUNTIF(is_conflict)           AS n_conflicts,
        COUNT(*)                       AS n_members_recorded,
        LOGICAL_OR(is_rezoning)        AS is_rezoning
    FROM {{ ref('core_ca_vancouver_votes') }}
    GROUP BY item_key
)

SELECT
    i.*,
    cat.dataset_title AS source_name, cat.dataset_page_url AS source_url,
    cat.license_title AS source_license, cat.rows_updated_at AS source_rows_updated_at
FROM items i
CROSS JOIN cat
-- "Contested" means BOTH sides voted. A unanimous rejection (11 opposed,
-- 0 in favour) is a decision, not a contest, and it topped the first cut of
-- this list. Rank by the smaller side (closest splits first), then by how
-- many stood against, then most recent.
WHERE i.n_opposition > 0 AND i.n_in_favour > 0
ORDER BY LEAST(i.n_opposition, i.n_in_favour) DESC, i.n_opposition DESC, i.vote_date DESC
LIMIT 25
