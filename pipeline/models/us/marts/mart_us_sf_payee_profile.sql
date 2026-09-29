-- =============================================================================
-- Mart: SF payee profile — what one payee is actually paid for
--
-- Sources: core_us_sf_vouchers (row-level payment lines),
--          mart_us_sf_payees_search (the vendor universe),
--          int_us_sf_sub_objects (purchase / obligation / ledger),
--          core_us_sf_source_catalog (provenance).
-- Grain:   one row per vendor (raw Controller display string).
--
-- WHY THIS EXISTS. The payee fiche had money and nothing else: a total, a
-- bar per fiscal year, and a bare list of department NAMES with no amounts.
-- Paris fills that slot for free — a supplier is keyed by SIREN, so SIRENE
-- returns its activity label, legal form, head office and headcount
-- (FournisseurFiche). SF vendors carry no identifier at all, so there is no
-- registry to join and the fiche said nothing about the payee.
--
-- What the voucher file DOES carry is the City's own account coding on every
-- line: which department paid, and which sub-object it was booked to
-- ("Food", "Interpreters", "Lumber", "Rent/Lease-Building/Structure"). That
-- answers the reader's real question — what does the City pay them FOR —
-- from the source itself, with no enrichment and nothing invented.
--
-- Three rollups, each per vendor:
--   departments  — all-time department split WITH dollars (the fiche used to
--                  render these as a "·"-joined name list).
--   categories   — FY2018+ sub-object split, carrying spend_class so a
--                  payee whose money is debt service or a benefit plan is
--                  not described as though the City bought something.
--   recent_lines — the vendor's most recent CLOSED fiscal year, broken into
--                  department x sub-object lines. This is the honest analog
--                  of Paris's dated "recent contracts" table: SF vouchers
--                  carry NO payment date, only fiscal_year, so a dated
--                  ledger cannot be built from this source — the last closed
--                  year's composition is as close as the data allows.
--
-- FY2018 floor on categories (NOT on departments): the chart of accounts was
-- renumbered that year, so a sub-object series across the break silently
-- splits — the same floor mart_us_sf_spending_subobjects already respects.
-- Department names survive the break, so their rollup stays all-time.
--
-- Totals are NET (refund/credit lines included) so a vendor's rollups tie to
-- its own by_year series in payees_search. Negative cells are kept in the
-- data and filtered at the display layer, never silently dropped here.
-- =============================================================================

WITH universe AS (
    SELECT vendor
    FROM {{ ref('mart_us_sf_payees_search') }}
),

lines AS (
    SELECT v.*
    FROM {{ ref('core_us_sf_vouchers') }} v
    INNER JOIN universe u USING (vendor)
),

-- ── departments: all-time, with dollars ──────────────────────────────────
-- Grouped on department_code, NOT the display name: the FY2018 PeopleSoft
-- migration re-cased every label, so "HOM Homelessness Services" and
-- "HOM HOMELESSNESS SERVICES" are the same department and would otherwise
-- occupy two rows of the fiche's top-8 with the money split between them.
-- The label is the dominant spelling by dollars (deterministic, no MAX() on
-- a display string).
dept_labels AS (
    SELECT department_code, department
    FROM (
        SELECT
            department_code,
            department,
            ROW_NUMBER() OVER (
                PARTITION BY department_code
                ORDER BY SUM(vouchers_paid) DESC, department
            ) AS rn
        FROM lines
        WHERE department_code IS NOT NULL
        GROUP BY department_code, department
    )
    WHERE rn = 1
),

dept_cells AS (
    SELECT
        l.vendor,
        dl.department,
        l.department_code,
        SUM(l.vouchers_paid)      AS usd,
        COUNT(DISTINCT l.voucher) AS n_vouchers
    FROM lines l
    INNER JOIN dept_labels dl USING (department_code)
    WHERE l.department_code IS NOT NULL
    GROUP BY 1, 2, 3
),

dept_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY vendor ORDER BY usd DESC, department
        ) AS rn,
        COUNT(*)   OVER (PARTITION BY vendor) AS n_departments,
        SUM(usd)   OVER (PARTITION BY vendor) AS dept_total_usd
    FROM dept_cells
),

dept_agg AS (
    SELECT
        vendor,
        ANY_VALUE(n_departments)   AS n_departments,
        ANY_VALUE(dept_total_usd)  AS dept_total_usd,
        ARRAY_AGG(
            STRUCT(department, department_code, usd, n_vouchers)
            ORDER BY usd DESC, department
        ) AS departments
    FROM dept_ranked
    WHERE rn <= 8
    GROUP BY vendor
),

-- ── categories: FY2018+ sub-object split, class-aware ────────────────────
-- Same dominant-label treatment as the departments, for the same reason.
subobj_labels AS (
    SELECT sub_object_code, sub_object
    FROM (
        SELECT
            sub_object_code,
            sub_object,
            ROW_NUMBER() OVER (
                PARTITION BY sub_object_code
                ORDER BY SUM(vouchers_paid) DESC, sub_object
            ) AS rn
        FROM lines
        WHERE fiscal_year >= 2018 AND sub_object_code IS NOT NULL
        GROUP BY sub_object_code, sub_object
    )
    WHERE rn = 1
),

cat_cells AS (
    SELECT
        l.vendor,
        l.sub_object_code,
        sl.sub_object,
        COALESCE(k.spend_class, 'unclear') AS spend_class,
        SUM(l.vouchers_paid)               AS usd,
        COUNT(DISTINCT l.voucher)          AS n_vouchers
    FROM lines l
    INNER JOIN subobj_labels sl USING (sub_object_code)
    LEFT JOIN {{ ref('int_us_sf_sub_objects') }} k
        USING (sub_object_code)
    WHERE l.fiscal_year >= 2018
      AND l.sub_object_code IS NOT NULL
    GROUP BY 1, 2, 3, 4
),

cat_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY vendor ORDER BY usd DESC, sub_object
        ) AS rn,
        COUNT(*) OVER (PARTITION BY vendor) AS n_categories,
        SUM(usd) OVER (PARTITION BY vendor) AS cat_total_usd
    FROM cat_cells
),

cat_agg AS (
    SELECT
        vendor,
        ANY_VALUE(n_categories)  AS n_categories,
        ANY_VALUE(cat_total_usd) AS categories_total_usd,
        ARRAY_AGG(
            STRUCT(sub_object_code, sub_object, spend_class, usd, n_vouchers)
            ORDER BY usd DESC, sub_object
        ) AS categories
    FROM cat_ranked
    WHERE rn <= 8
    GROUP BY vendor
),

-- ── recent lines: the vendor's last CLOSED fiscal year ────────────────────
-- "Closed" per the shared execution-status macro, not the calendar boolean:
-- a year whose accounting close is still running must not be presented as
-- a finished picture of what the City bought.
vendor_fy AS (
    SELECT
        vendor,
        fiscal_year,
        SUM(vouchers_paid) AS usd
    FROM lines
    GROUP BY 1, 2
),

last_closed_fy AS (
    SELECT vendor, MAX(fiscal_year) AS recent_fy
    FROM vendor_fy
    WHERE usd != 0
      AND {{ us_sf_execution_status('fiscal_year', basis='actuals') }} = 'closed'
    GROUP BY vendor
),

recent_cells AS (
    SELECT
        l.vendor,
        l.fiscal_year,
        dl.department,
        l.department_code,
        COALESCE(sl.sub_object, l.sub_object) AS sub_object,
        COALESCE(k.spend_class, 'unclear')    AS spend_class,
        SUM(l.vouchers_paid)                  AS usd,
        COUNT(DISTINCT l.voucher)             AS n_vouchers
    FROM lines l
    INNER JOIN last_closed_fy f
        ON f.vendor = l.vendor AND f.recent_fy = l.fiscal_year
    INNER JOIN dept_labels dl USING (department_code)
    LEFT JOIN subobj_labels sl USING (sub_object_code)
    LEFT JOIN {{ ref('int_us_sf_sub_objects') }} k
        USING (sub_object_code)
    WHERE l.department_code IS NOT NULL
    GROUP BY 1, 2, 3, 4, 5, 6
),

recent_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY vendor ORDER BY usd DESC, department, sub_object
        ) AS rn,
        COUNT(*) OVER (PARTITION BY vendor) AS n_recent_lines,
        SUM(usd) OVER (PARTITION BY vendor) AS recent_total_usd
    FROM recent_cells
),

recent_agg AS (
    SELECT
        vendor,
        ANY_VALUE(fiscal_year)       AS recent_fy,
        ANY_VALUE(n_recent_lines)    AS n_recent_lines,
        ANY_VALUE(recent_total_usd)  AS recent_total_usd,
        ARRAY_AGG(
            STRUCT(department, department_code, sub_object, spend_class, usd, n_vouchers)
            ORDER BY usd DESC, department, sub_object
        ) AS recent_lines
    FROM recent_ranked
    WHERE rn <= 6
    GROUP BY vendor
),

totals AS (
    SELECT
        vendor,
        SUM(vouchers_paid)      AS total_paid_usd,
        COUNT(DISTINCT voucher) AS n_vouchers,
        MIN(fiscal_year)        AS first_fy,
        MAX(fiscal_year)        AS last_fy
    FROM lines
    GROUP BY vendor
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
    t.vendor,
    t.total_paid_usd,
    t.n_vouchers,
    t.first_fy,
    t.last_fy,
    d.n_departments,
    d.dept_total_usd,
    d.departments,
    c.n_categories,
    c.categories_total_usd,
    c.categories,
    r.recent_fy,
    r.n_recent_lines,
    r.recent_total_usd,
    r.recent_lines,
    -- Same provenance aliases as every other SF mart (source_* rather than
    -- dataset_*), so the shared not_null tests and the export's _source()
    -- helper read it without a special case.
    p.dataset_id        AS source_dataset_id,
    p.dataset_name      AS source_name,
    p.dataset_page_url  AS source_url,
    p.attribution       AS source_attribution,
    p.rows_updated_at   AS source_rows_updated_at
FROM totals t
LEFT JOIN dept_agg   d USING (vendor)
LEFT JOIN cat_agg    c USING (vendor)
LEFT JOIN recent_agg r USING (vendor)
CROSS JOIN provenance p
