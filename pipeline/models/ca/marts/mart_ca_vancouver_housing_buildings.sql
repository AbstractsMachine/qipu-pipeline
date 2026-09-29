-- =============================================================================
-- Mart: non-market housing, one row per building the City lists (641), typed
-- out of the place's published facts: status, occupancy year, operator, units
-- by clientele and by bedroom count, accessible units, local area, place_id
-- (the place fiche). units = families + seniors + other clientele.
-- The register splits the same homes a second way, by design (studio, room,
-- 1–4 bedrooms), and the two counts DISAGREE for 36 of 641 buildings (40,658
-- by clientele vs 40,709 by design, measured 2026-09-13) — e.g. a hotel
-- listing 41 rooms and 0 clientele units. Both travel: units_by_design and
-- splits_agree; the page reports the gap instead of choosing.
-- operator_payee_key: the SOFI payee that is the same organisation as the
-- operator — the same ca_org_key the payees and the contract vendors join on,
-- through any spelling the payee was printed under, named payees only. What the
-- City paid that organisation is ALL its payments (services, grants), not what
-- it spent on housing; the page says so. The City itself is never its own
-- payee (the register lists City-run buildings under "City of Vancouver").
-- Where the exact key misses only because the register and the schedule
-- spell the organisation differently ("BC Housing" / "BC Housing Management
-- Commission"), seed_ca_vancouver_housing_operator_payees gives the payee,
-- reviewed row by row (named payees only; the exact join wins).
-- operator: one spelling per organisation — the register prints "More Than a
-- Roof Housing Society" and "More Than A Roof Housing Society"; spellings that
-- differ only in capitals take the most frequent one (then the first), so the
-- page and the operator's fiche count one operator, not two.
-- =============================================================================

{{ config(materialized='table', schema='ca_marts', tags=['ca', 'marts']) }}

WITH printed AS (
    SELECT DISTINCT payee_key, payee_key_printed
    FROM {{ ref('core_ca_vancouver_sofi_payments') }}
    WHERE payee_key != ''
),

op_payee AS (
    SELECT pr.payee_key_printed AS operator_key, pr.payee_key
    FROM printed pr
    JOIN {{ ref('mart_ca_vancouver_payees') }} py USING (payee_key)
    WHERE pr.payee_key != 'city-of-vancouver'
),

op_seed AS (
    SELECT LOWER(s.operator) AS k, s.payee_key
    FROM {{ ref('seed_ca_vancouver_housing_operator_payees') }} s
    JOIN {{ ref('mart_ca_vancouver_payees') }} py USING (payee_key)
),

b AS (
SELECT
    place_id,
    place_name,
    address,
    local_area,
    lon, lat, url, block_idx,
    JSON_VALUE(facts, '$.project_status')                          AS project_status,
    SAFE_CAST(JSON_VALUE(facts, '$.occupancy_year') AS INT64)      AS occupancy_year,
    JSON_VALUE(facts, '$.operator')                                AS operator,
    SAFE_CAST(JSON_VALUE(facts, '$.clientele_families') AS INT64)  AS units_families,
    SAFE_CAST(JSON_VALUE(facts, '$.clientele_seniors') AS INT64)   AS units_seniors,
    SAFE_CAST(JSON_VALUE(facts, '$.clientele_other') AS INT64)     AS units_other,
    COALESCE(SAFE_CAST(JSON_VALUE(facts, '$.clientele_families') AS INT64), 0)
      + COALESCE(SAFE_CAST(JSON_VALUE(facts, '$.clientele_seniors') AS INT64), 0)
      + COALESCE(SAFE_CAST(JSON_VALUE(facts, '$.clientele_other') AS INT64), 0) AS units,
    SAFE_CAST(JSON_VALUE(facts, '$.units_studio') AS INT64)        AS units_studio,
    SAFE_CAST(JSON_VALUE(facts, '$.units_room') AS INT64)          AS units_room,
    SAFE_CAST(JSON_VALUE(facts, '$.units_1br') AS INT64)           AS units_1br,
    SAFE_CAST(JSON_VALUE(facts, '$.units_2br') AS INT64)           AS units_2br,
    SAFE_CAST(JSON_VALUE(facts, '$.units_3br') AS INT64)           AS units_3br,
    SAFE_CAST(JSON_VALUE(facts, '$.units_4br') AS INT64)           AS units_4br,
    SAFE_CAST(JSON_VALUE(facts, '$.units_accessible') AS INT64)    AS units_accessible,
    SAFE_CAST(JSON_VALUE(facts, '$.units_studio') AS INT64) + SAFE_CAST(JSON_VALUE(facts, '$.units_room') AS INT64)
      + SAFE_CAST(JSON_VALUE(facts, '$.units_1br') AS INT64) + SAFE_CAST(JSON_VALUE(facts, '$.units_2br') AS INT64)
      + SAFE_CAST(JSON_VALUE(facts, '$.units_3br') AS INT64) + SAFE_CAST(JSON_VALUE(facts, '$.units_4br') AS INT64) AS units_by_design,
    (COALESCE(SAFE_CAST(JSON_VALUE(facts, '$.clientele_families') AS INT64), 0)
      + COALESCE(SAFE_CAST(JSON_VALUE(facts, '$.clientele_seniors') AS INT64), 0)
      + COALESCE(SAFE_CAST(JSON_VALUE(facts, '$.clientele_other') AS INT64), 0))
    = (SAFE_CAST(JSON_VALUE(facts, '$.units_studio') AS INT64) + SAFE_CAST(JSON_VALUE(facts, '$.units_room') AS INT64)
      + SAFE_CAST(JSON_VALUE(facts, '$.units_1br') AS INT64) + SAFE_CAST(JSON_VALUE(facts, '$.units_2br') AS INT64)
      + SAFE_CAST(JSON_VALUE(facts, '$.units_3br') AS INT64) + SAFE_CAST(JSON_VALUE(facts, '$.units_4br') AS INT64)) AS splits_agree,
    n_council, n_permits, n_heritage,
    source_name, source_url, source_license, source_rows_updated_at
FROM {{ ref('mart_ca_vancouver_places') }}
WHERE place_kind = 'non_market_housing'
),

spelling AS (
    SELECT LOWER(operator) AS k,
           ARRAY_AGG(operator ORDER BY n DESC, operator LIMIT 1)[OFFSET(0)] AS operator
    FROM (SELECT operator, COUNT(*) AS n FROM b WHERE operator IS NOT NULL GROUP BY 1)
    GROUP BY 1
)

SELECT b.* REPLACE (sp.operator AS operator), COALESCE(op.payee_key, os.payee_key) AS operator_payee_key
FROM b
LEFT JOIN spelling sp ON sp.k = LOWER(b.operator)
LEFT JOIN op_payee op ON op.operator_key = {{ ca_org_key('b.operator') }}
LEFT JOIN op_seed os ON os.k = LOWER(b.operator)
