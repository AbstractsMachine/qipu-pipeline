-- =============================================================================
-- Core: SF Vendor Payments OBT — row-level voucher distribution lines
--
-- Source: stg_us_sf_vouchers (~8.07M rows)
-- Grain:  voucher × accounting distribution line — kept row-level per
--         ADR-0001 (core = row-level OBT; the FY × vendor rollup is
--         mart_us_sf_top_payees' business).
--
-- `vendor` stays the portal's unkeyed display string here — name
-- normalization/bucketing is a display concern handled in the mart via
-- seed_us_sf_payee_buckets (same philosophy as the Paris association
-- name-normalization enrichment, docs/us/API-RECON.md §D.3.6).
-- =============================================================================

WITH vouchers AS (
    SELECT *
    FROM {{ ref('stg_us_sf_vouchers') }}
),

-- Manual payee classification (seed, display only — never touches amounts).
payee_buckets AS (
    SELECT vendor, bucket, classification_note, classification_method,
           classified_at, is_aggregation_line
    FROM {{ ref('stg_us_sf_payee_buckets') }}
),

-- Normalized payee identity (seed, display/keying only — never touches amounts).
payee_identity AS (
    SELECT vendor, payee_slug, payee_name, merge_reason
    FROM {{ ref('stg_us_sf_payee_identity') }}
),

-- Sub-object spend classification (purchase / obligation / ledger / unclear).
subobject_class AS (
    SELECT sub_object_code, spend_class, basis, needs_review
    FROM {{ ref('stg_us_sf_subobject_class') }}
)

SELECT
    v.*,
    v.related_govt_units = 'Yes'  AS is_related_govt_unit,
    CURRENT_DATE('America/Los_Angeles') > DATE(v.fiscal_year, 6, 30)
                                AS is_fiscal_year_complete
    ,
    -- payee bucket (stg_us_sf_payee_buckets, keyed on the raw vendor string)
    pb.bucket                          AS payee_bucket,
    pb.classification_note             AS payee_bucket_note,
    pb.classification_method           AS payee_bucket_method,
    pb.classified_at                   AS payee_bucket_classified_at,
    pb.is_aggregation_line             AS is_aggregation_line,
    pb.vendor IS NOT NULL              AS is_payee_bucketed,
    -- normalized payee (stg_us_sf_payee_identity); NULL outside the keyed set
    pi.payee_slug,
    pi.payee_name,
    pi.merge_reason                    AS payee_merge_reason,
    -- sub-object spend class (stg_us_sf_subobject_class)
    sc.spend_class                     AS sub_object_spend_class,
    sc.basis                           AS sub_object_spend_class_basis,
    sc.needs_review                    AS sub_object_spend_class_needs_review
FROM vouchers v
LEFT JOIN payee_buckets pb   ON pb.vendor = v.vendor
LEFT JOIN payee_identity pi  ON pi.vendor = v.vendor
LEFT JOIN subobject_class sc ON sc.sub_object_code = v.sub_object_code
