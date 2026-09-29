-- =============================================================================
-- Mart: what San Francisco actually buys — spending by sub-object
--
-- Sources: core_us_sf_vouchers (row-level payment lines),
--          int_us_sf_sub_objects (purchase / obligation / ledger),
--          core_us_sf_source_catalog (provenance).
-- Grain:   fiscal_year × sub_object_code.
--
-- Replaces a hand-curated six-line "what a payment buys" strip with the whole
-- ledger, split honestly. Two design decisions worth keeping:
--
--  1. SUB-OBJECT, not object. The object level is too coarse to read: one
--     $3.4B bucket called "Professional/Specialized Svcs" (FY2025, 20% of all
--     payments). Sub-object splits it into Other Professional Services /
--     Management Consulting / Engineering / Systems Consulting.
--
--  2. FY2018+ ONLY. The chart of accounts was renumbered at FY2018 — the same
--     concept is `567 Blds;Structures & Improvements` until FY2017 and
--     `BLD_STR_IMP Bldg: Structures/Improvements` after. Codes are stable
--     WITHIN each era (0 codes carry two labels) but not across it, so a
--     series spanning the break would silently split. Same FY2018 cliff the
--     payee and contract drills already respect.
--
-- The exemplar is DERIVED (the largest vendor × department line in the cell),
-- never curated: it cannot be cherry-picked and it refreshes each year on its
-- own. Related-government-unit lines are excluded from the exemplar only, so
-- a category is never illustrated by an internal transfer — the totals still
-- carry every dollar.
--
-- `top_payees` is the drill list behind a clicked category. It ranks positive
-- lines only, but — unlike the exemplar — it does NOT exclude related
-- government units. That exclusion is right for an ILLUSTRATION (a category
-- should not be introduced by an internal transfer) and wrong for a LISTING:
-- the City's health-plan categories are paid entirely through the Health
-- Service System, a related unit, so excluding them left those categories
-- with an empty drill list and made Kaiser's and Blue Shield's own fiches a
-- column of dead labels. A reader opening a category wants everyone who was
-- paid in it; the paying department is on every row and says what it is.
-- =============================================================================

WITH vouchers AS (
    SELECT *
    FROM {{ ref('core_us_sf_vouchers') }}
    WHERE fiscal_year >= 2018
      AND sub_object_code IS NOT NULL
),

cells AS (
    SELECT
        fiscal_year,
        sub_object_code,
        SUM(vouchers_paid)              AS paid_usd,
        COUNT(*)                        AS n_voucher_lines,
        COUNT(DISTINCT vendor)          AS n_vendors,
        COUNT(DISTINCT department_code) AS n_departments
    FROM vouchers
    GROUP BY fiscal_year, sub_object_code
),

-- Largest single vendor × department line in each cell: the concrete example.
exemplar_ranked AS (
    SELECT
        fiscal_year,
        sub_object_code,
        vendor,
        department,
        department_code,
        SUM(vouchers_paid) AS exemplar_usd,
        ROW_NUMBER() OVER (
            PARTITION BY fiscal_year, sub_object_code
            ORDER BY SUM(vouchers_paid) DESC, vendor
        ) AS rn
    FROM vouchers
    -- Exemplar only: positive lines from non-related units, so a category is
    -- never illustrated by a refund or an internal transfer. Totals above are
    -- NET (they carry the refund lines) and therefore tie to the page's own
    -- FY total — the two must not disagree by the reversals.
    WHERE NOT is_related_govt_unit AND vouchers_paid > 0
    GROUP BY fiscal_year, sub_object_code, vendor, department, department_code
),

exemplar AS (
    SELECT
        fiscal_year,
        sub_object_code,
        vendor          AS exemplar_vendor,
        department      AS exemplar_department,
        department_code AS exemplar_department_code,
        exemplar_usd
    FROM exemplar_ranked
    WHERE rn = 1
),

-- The drill list behind a clicked category: every positive line, related
-- units included (see the header), kept to 6 rows. `n_payees_ranked` is the
-- full count BEFORE the cut, so the UI can say how many are not shown rather
-- than implying the list is complete.
drill_ranked AS (
    SELECT
        fiscal_year,
        sub_object_code,
        vendor,
        department,
        department_code,
        SUM(vouchers_paid) AS usd,
        ROW_NUMBER() OVER (
            PARTITION BY fiscal_year, sub_object_code
            ORDER BY SUM(vouchers_paid) DESC, vendor
        ) AS rn,
        COUNT(*) OVER (
            PARTITION BY fiscal_year, sub_object_code
        ) AS n_ranked
    FROM vouchers
    WHERE vouchers_paid > 0
    GROUP BY fiscal_year, sub_object_code, vendor, department, department_code
),

top_payees AS (
    SELECT
        fiscal_year,
        sub_object_code,
        ANY_VALUE(n_ranked) AS n_payees_ranked,
        ARRAY_AGG(
            STRUCT(vendor, department, department_code, usd)
            ORDER BY usd DESC, vendor
        ) AS top_payees
    FROM drill_ranked
    WHERE rn <= 6
    GROUP BY fiscal_year, sub_object_code
),

-- The label is stable per code within the modern era; the dominant-row pick
-- keeps it deterministic anyway (no MAX()/ANY_VALUE on a display string).
labels AS (
    SELECT sub_object_code, sub_object
    FROM (
        SELECT
            sub_object_code,
            sub_object,
            ROW_NUMBER() OVER (
                PARTITION BY sub_object_code
                ORDER BY SUM(vouchers_paid) DESC, sub_object
            ) AS rn
        FROM vouchers
        GROUP BY sub_object_code, sub_object
    )
    WHERE rn = 1
),

provenance AS (
    SELECT DISTINCT
        dataset_id,
        dataset_name,
        dataset_page_url,
        attribution,
        rows_updated_at
    FROM {{ ref('core_us_sf_source_catalog') }}
    WHERE source_id = 'sf_vouchers'
)

SELECT
    c.fiscal_year,
    c.sub_object_code,
    l.sub_object,
    COALESCE(k.spend_class, 'unclear')          AS spend_class,
    k.needs_review                              AS class_needs_review,
    c.paid_usd,
    c.n_voucher_lines,
    c.n_vendors,
    c.n_departments,
    SAFE_DIVIDE(c.paid_usd, SUM(c.paid_usd) OVER (PARTITION BY c.fiscal_year))
                                                AS share_of_year,
    SAFE_DIVIDE(
        c.paid_usd,
        SUM(c.paid_usd) OVER (
            PARTITION BY c.fiscal_year, COALESCE(k.spend_class, 'unclear')
        )
    )                                           AS share_of_class,
    e.exemplar_vendor,
    e.exemplar_department,
    e.exemplar_department_code,
    e.exemplar_usd,
    tp.n_payees_ranked,
    tp.top_payees,
    p.dataset_id,
    p.dataset_name,
    p.dataset_page_url,
    p.attribution,
    p.rows_updated_at
FROM cells c
LEFT JOIN labels l    USING (sub_object_code)
LEFT JOIN {{ ref('int_us_sf_sub_objects') }} k USING (sub_object_code)
LEFT JOIN exemplar e  USING (fiscal_year, sub_object_code)
LEFT JOIN top_payees tp USING (fiscal_year, sub_object_code)
CROSS JOIN provenance p
