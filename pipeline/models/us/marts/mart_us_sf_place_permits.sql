-- =============================================================================
-- Mart: construction permits on a place's parcels (Block 6D — the APN join)
--
-- Grain: one row per (place_slug, permit_number).
--
-- The structured, ~100%-precision money-at-location join: the place's
-- facility parcels (core_us_sf_places.block_lot) → all building
-- permits on those APNs. "Construction on this parcel" — declared value,
-- description, status, date. Rescues even places bonds/contracts miss (Coit
-- Tower rehab; the Chinatown Library $19M renovation).
--
-- Money note: revised_cost is the applicant's DECLARED construction value — a
-- permit-ledger measure, NOT city spend, and the SAME job as the contract that
-- built it. Never summed with contract paid / bond expended (capital no-sum).
-- Only meaningful, non-trivial permits are kept (declared value ≥ $1,000) so
-- the "street space"/address-tag noise ($1 permits) doesn't crowd the fiche.
-- =============================================================================

WITH place_apns AS (
    SELECT DISTINCT place_slug, block_lot
    FROM {{ ref('core_us_sf_places') }}
    WHERE block_lot IS NOT NULL AND block_lot != ''
),

permits AS (
    SELECT
        permit_number, block_lot, description, permit_type,
        estimated_cost_usd, revised_cost_usd, status,
        issued_date, filed_date, completed_date
    FROM {{ ref('core_us_sf_building_permits') }}
),

joined AS (
    SELECT
        pa.place_slug,
        p.permit_number,
        p.description,
        p.permit_type,
        COALESCE(p.revised_cost_usd, p.estimated_cost_usd) AS declared_cost_usd,
        p.status,
        COALESCE(p.issued_date, p.filed_date)              AS permit_date,
        p.completed_date
    FROM place_apns pa
    JOIN permits p USING (block_lot)
    WHERE COALESCE(p.revised_cost_usd, p.estimated_cost_usd) >= 1000
)

SELECT
    place_slug,
    permit_number,
    description,
    permit_type,
    declared_cost_usd,
    status,
    -- Did this permit ever become work? An application is not construction.
    -- Measured on this mart (2026-07-28): $576M of declared value sits on
    -- WITHDRAWN permits, $440M on expired ones and $430M on applications merely
    -- filed. Fire Station 13's headline figure was almost entirely a 19-storey
    -- hotel permit withdrawn in 2019 — money nobody ever spent, displayed as
    -- though it had been. Only issued/completed/reinstated permits may be
    -- totalled; the rest stay visible as rows, carrying their status.
    LOWER(TRIM(status)) IN ('complete', 'issued', 'reinstated') AS is_effective,
    permit_date,
    completed_date,
    EXTRACT(YEAR FROM permit_date) AS permit_year
FROM joined
