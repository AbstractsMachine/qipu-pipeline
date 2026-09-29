-- =============================================================================
-- Mart: enriched recipient profiles (recipient grain, orgs only).
--
-- Totals come from int_br_recife_credor_ano (summed over years); the `ode_*`
-- columns and the theme come from core_br_recife_credor and are LEFT-joined in and NEVER overwrite the raw credor totals. Recipients with no
-- enrichment yet keep NULL ode_* (partial enrichment is honest, not lossy).
--
--   ode_razao_social / ode_cnae_* / ode_porte / ode_situacao  ← Receita Federal
--   ode_tema           ← COALESCE(CNAE-section seed, paying-agency regex seed,
--                          'Outros') — deterministic, grounded
--   ode_resumo / ode_o_que_financia  ← plain-pt LLM vulgarization (tail)
--
-- ode_* = "open-data-enrichment" (same convention as core_subventions).
-- =============================================================================

WITH base AS (
    SELECT
        recipient_key                                            AS cnpj,
        SUM(total_pago)                                          AS total_pago,
        SUM(total_empenhado)                                     AS total_empenhado,
        SUM(subvencao_pago)                                      AS subvencao_pago,
        LOGICAL_OR(is_subvencao_any)                             AS is_subvencao
    FROM {{ ref('int_br_recife_credor_ano') }}
    GROUP BY recipient_key
),

credor AS (
    SELECT * FROM {{ ref('core_br_recife_credor') }}
),

provenance AS (
    SELECT
        ANY_VALUE(dataset_title)     AS source_name,
        ANY_VALUE(dataset_page_url)  AS source_url,
        ANY_VALUE(portal_name)       AS source_portal,
        ANY_VALUE(license_title)     AS source_license,
        MAX(rows_updated_at)         AS rows_updated_at
    FROM {{ ref('core_br_recife_source_catalog') }}
    WHERE source_id LIKE 'credor_%'
)

SELECT
    b.cnpj,
    c.nome,
    b.total_pago,
    b.total_empenhado,
    b.subvencao_pago,
    b.is_subvencao,
    c.principal_orgao,
    c.ode_razao_social,
    c.ode_cnae_codigo,
    c.ode_cnae_descricao,
    c.ode_cnae_secao,
    c.ode_porte,
    c.ode_natureza_juridica,
    c.ode_situacao,
    c.ode_municipio,
    c.ode_uf,
    c.ode_tema,
    c.ode_tema_fonte,
    c.ode_resumo,
    c.ode_o_que_financia,
    c.ode_resumo_model,
    'BRL'                       AS unit,
    p.source_name,
    p.source_url,
    p.rows_updated_at           AS source_rows_updated_at
FROM base b
LEFT JOIN credor c ON c.cnpj = b.cnpj
CROSS JOIN provenance p
