-- =============================================================================
-- Core: one reading per council record, publishable readings only.
--
-- A held reading (stg is_held) keeps no line and no interest here: a score read
-- from a sentence nobody may see would rank an invisible record above a visible
-- one. Its classification is dropped with it. Absent means "not read", never
-- "read and found small".
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core']) }}

SELECT
    record_key, source, plain_line, interest, interest_band, record_type, topic, subtopic, action, subjects,
    reading_version, read_by, read_at
FROM {{ ref('stg_ca_vancouver_council_readings') }}
WHERE NOT COALESCE(is_held, FALSE) AND plain_line IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY record_key ORDER BY read_at DESC) = 1
