-- =============================================================================
-- Core: issued building permits, one row per permit with a location.
-- `work_class`: new_building | demolition | alteration | other, from the City's
-- own type_of_work. Permits without a published point are kept out of the map
-- core (they cannot be placed) and counted in the export note.
-- =============================================================================

{{ config(materialized='table', schema='ca_analytics', tags=['ca', 'core', 'citymap']) }}

SELECT
    permit_number,
    issue_date,
    EXTRACT(YEAR FROM issue_date) AS issue_year,
    project_value_cad,
    type_of_work,
    CASE
        WHEN type_of_work = 'New Building'                THEN 'new_building'
        WHEN type_of_work = 'Demolition / Deconstruction' THEN 'demolition'
        WHEN type_of_work = 'Addition / Alteration'       THEN 'alteration'
        ELSE 'other'
    END AS work_class,
    address,
    local_area,
    ST_X(ST_CENTROID(geog)) AS lon,
    ST_Y(ST_CENTROID(geog)) AS lat,
    _synced_at
FROM {{ ref('stg_ca_vancouver_building_permits') }}
WHERE geog IS NOT NULL AND permit_number IS NOT NULL AND issue_date IS NOT NULL
