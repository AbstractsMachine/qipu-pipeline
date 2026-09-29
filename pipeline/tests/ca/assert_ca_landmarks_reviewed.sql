-- The curated landmarks (seed_ca_vancouver_landmarks) stay sound:
--   · a slug is unique, and never another place's register id (its page
--     would answer for two places);
--   · a family is one of the section's, a point sits in Vancouver, the point
--     and the evidence say where they come from;
--   · every register id is on the City's registers, and belongs to one
--     landmark only;
--   · every operator payee key is a NAMED payee with grant lines, on one
--     landmark only — a seed row can never publish a withheld name;
--   · a landmark carries at least one sourced amount (the section lists only
--     places whose link to City money can be shown).
WITH s AS (SELECT * FROM {{ ref('seed_ca_vancouver_landmarks') }}),
reg AS (
    SELECT s.slug, TRIM(r) AS register_id
    FROM s, UNNEST(SPLIT(COALESCE(s.register_ids, ''), ';')) AS r
    WHERE TRIM(r) != ''
),
op AS (
    SELECT s.slug, TRIM(k) AS payee_key
    FROM s, UNNEST(SPLIT(COALESCE(s.operator_payee_keys, ''), ';')) AS k
    WHERE TRIM(k) != ''
),
places AS (SELECT place_id FROM {{ ref('core_ca_vancouver_places') }}),
money AS (
    SELECT slug, COUNTIF(amount_cad != 0) AS n
    FROM {{ ref('core_ca_vancouver_landmark_money') }}
    GROUP BY 1
)
SELECT slug, 'slug twice' AS problem FROM s GROUP BY slug HAVING COUNT(*) > 1
UNION ALL
SELECT s.slug, "slug is another place's register id" FROM s JOIN places p ON p.place_id = s.slug
  WHERE s.slug NOT IN (SELECT register_id FROM reg WHERE reg.slug = s.slug)
UNION ALL
SELECT slug, CONCAT('unknown family ', family) FROM s WHERE family NOT IN ('culture', 'parks', 'community', 'civic')
UNION ALL
SELECT slug, 'point outside Vancouver' FROM s WHERE NOT (lat BETWEEN 49.19 AND 49.32 AND lon BETWEEN -123.23 AND -123.02)
UNION ALL
SELECT slug, 'no kind' FROM s WHERE kind IS NULL OR TRIM(kind) = ''
UNION ALL
SELECT slug, 'no coord_source' FROM s WHERE coord_source IS NULL OR TRIM(coord_source) = ''
UNION ALL
SELECT slug, 'no evidence' FROM s WHERE evidence IS NULL OR TRIM(evidence) = ''
UNION ALL
SELECT reg.slug, CONCAT('register id not on the registers: ', reg.register_id) FROM reg LEFT JOIN places p ON p.place_id = reg.register_id WHERE p.place_id IS NULL
UNION ALL
SELECT ANY_VALUE(slug), CONCAT('register id on two landmarks: ', register_id) FROM reg GROUP BY register_id HAVING COUNT(DISTINCT slug) > 1
UNION ALL
SELECT ANY_VALUE(slug), CONCAT('payee key on two landmarks: ', payee_key) FROM op GROUP BY payee_key HAVING COUNT(DISTINCT slug) > 1
UNION ALL
SELECT op.slug, CONCAT('payee key not a named payee with grants: ', op.payee_key)
FROM op LEFT JOIN {{ ref('mart_ca_vancouver_payees') }} p USING (payee_key)
WHERE p.payee_key IS NULL OR COALESCE(p.grant_total_cad, 0) <= 0
UNION ALL
SELECT s.slug, 'no sourced amount' FROM s LEFT JOIN money USING (slug) WHERE COALESCE(money.n, 0) = 0
