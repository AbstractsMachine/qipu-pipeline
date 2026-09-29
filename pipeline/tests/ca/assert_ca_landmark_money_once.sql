-- Every dollar tied to a landmark is tied once, and to a document:
--   · a record (a grant line, a capital program's budget year, a competition)
--     belongs to one landmark, one kind;
--   · a grant row is a line the SOFI printed on its GRANT schedule (supplier
--     payments to an operator are never counted);
--   · every row names its source document (and a grant its page).
WITH m AS (SELECT * FROM {{ ref('core_ca_vancouver_landmark_money') }})
SELECT kind, record_id, 'record on two landmarks' AS problem
FROM m GROUP BY kind, record_id HAVING COUNT(DISTINCT slug) > 1
UNION ALL
SELECT kind, record_id, 'record counted twice' FROM m GROUP BY kind, record_id HAVING COUNT(*) > 1
UNION ALL
SELECT m.kind, m.record_id, 'grant row not on the grant schedule'
FROM m LEFT JOIN {{ ref('core_ca_vancouver_sofi_payments') }} s ON s.line_id = m.record_id AND s.schedule = 'grants'
WHERE m.kind = 'grant' AND s.line_id IS NULL
UNION ALL
SELECT kind, record_id, 'no source document' FROM m WHERE source_url IS NULL OR source_url = ''
UNION ALL
SELECT kind, record_id, 'grant without its page' FROM m WHERE kind = 'grant' AND source_page IS NULL
UNION ALL
SELECT kind, record_id, 'no year' FROM m WHERE year IS NULL
