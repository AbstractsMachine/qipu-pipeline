-- =============================================================================
-- Mart: SF payments sliced three ways — who paid, which service area, what
-- kind of payee
--
-- Sources: core_us_sf_vouchers, int_us_sf_payees, core_us_sf_source_catalog.
-- Grain:   fiscal_year × dimension × key.
--
-- WHY. The who-gets-paid page had exactly ONE breakdown (what the money
-- bought) against the contracts page's four, so the reader could see what was
-- purchased and never who paid for it. These are the missing lenses, and they
-- are built to be TOGGLED: every dimension here sums to the same denominator,
-- the fiscal year's total payments, so switching lens re-cuts one pie instead
-- of quietly changing what is being measured.
--
--   department — the paying department (the City's own code).
--   org_group  — the Controller's seven service areas. The budget page's own
--                top-level grouping, so the two pages cut the money the same
--                way and a reader can carry one into the other.
--   kind       — the display bucket from seed_us_sf_payee_buckets (supplier /
--                nonprofit / healthcare / fiscal agent / pass-through /
--                person). Unmatched vendors land in 'unclassified' rather
--                than being dropped: the seed covers ~80% of dollars and the
--                gap is a fact about the classification, not a rounding
--                error to hide.
--
-- Labels are the dominant spelling by dollars, never MAX() on a display
-- string — the FY2018 PeopleSoft migration re-cased every department name, so
-- grouping on the label would split one department into two rows.
--
-- Totals are NET (refund lines included) and therefore tie to the same FY
-- total mart_us_sf_payees_by_fy publishes. `person` rows are kept in the
-- totals and labelled by the UI, never featured — the personnes-physiques
-- doctrine is a display rule, not a reason to under-count the ledger.
-- =============================================================================

WITH vouchers AS (
    SELECT *
    FROM {{ ref('core_us_sf_vouchers') }}
    WHERE vendor IS NOT NULL
),

fy_totals AS (
    SELECT fiscal_year, SUM(vouchers_paid) AS fy_total_usd
    FROM vouchers
    GROUP BY fiscal_year
),

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
        FROM vouchers
        WHERE department_code IS NOT NULL
        GROUP BY department_code, department
    )
    WHERE rn = 1
),

group_labels AS (
    SELECT organization_group_code, organization_group
    FROM (
        SELECT
            organization_group_code,
            organization_group,
            ROW_NUMBER() OVER (
                PARTITION BY organization_group_code
                ORDER BY SUM(vouchers_paid) DESC, organization_group
            ) AS rn
        FROM vouchers
        WHERE organization_group_code IS NOT NULL
        GROUP BY organization_group_code, organization_group
    )
    WHERE rn = 1
),

by_department AS (
    SELECT
        v.fiscal_year,
        'department'                AS dimension,
        v.department_code           AS key,
        l.department                AS label,
        SUM(v.vouchers_paid)        AS usd,
        COUNT(DISTINCT v.vendor)    AS n_payees,
        COUNT(*)                    AS n_lines
    FROM vouchers v
    INNER JOIN dept_labels l USING (department_code)
    WHERE v.department_code IS NOT NULL
    GROUP BY 1, 2, 3, 4
),

by_org_group AS (
    SELECT
        v.fiscal_year,
        'org_group'                 AS dimension,
        v.organization_group_code    AS key,
        l.organization_group         AS label,
        SUM(v.vouchers_paid)        AS usd,
        COUNT(DISTINCT v.vendor)    AS n_payees,
        COUNT(*)                    AS n_lines
    FROM vouchers v
    INNER JOIN group_labels l USING (organization_group_code)
    WHERE v.organization_group_code IS NOT NULL
    GROUP BY 1, 2, 3, 4
),

by_kind AS (
    SELECT
        v.fiscal_year,
        'kind'                                        AS dimension,
        COALESCE(b.bucket, 'unclassified')            AS key,
        COALESCE(b.bucket, 'unclassified')            AS label,
        SUM(v.vouchers_paid)                          AS usd,
        COUNT(DISTINCT v.vendor)                      AS n_payees,
        COUNT(*)                                      AS n_lines
    FROM vouchers v
    LEFT JOIN {{ ref('int_us_sf_payees') }} b
        ON b.vendor = v.vendor
    GROUP BY 1, 2, 3, 4
),

unioned AS (
    SELECT * FROM by_department
    UNION ALL SELECT * FROM by_org_group
    UNION ALL SELECT * FROM by_kind
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
    u.fiscal_year,
    u.dimension,
    u.key,
    u.label,
    u.usd,
    u.n_payees,
    u.n_lines,
    t.fy_total_usd,
    SAFE_DIVIDE(u.usd, t.fy_total_usd)          AS share_of_fy,
    ROW_NUMBER() OVER (
        PARTITION BY u.fiscal_year, u.dimension ORDER BY u.usd DESC, u.label
    )                                            AS rank_in_dimension,
    {{ us_sf_execution_status('u.fiscal_year', basis='actuals') }} AS execution_status,
    p.dataset_id        AS source_dataset_id,
    p.dataset_name      AS source_name,
    p.dataset_page_url  AS source_url,
    p.attribution       AS source_attribution,
    p.rows_updated_at   AS source_rows_updated_at
FROM unioned u
INNER JOIN fy_totals t USING (fiscal_year)
CROSS JOIN provenance p
