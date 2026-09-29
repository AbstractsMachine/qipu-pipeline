-- =============================================================================
-- Mart: Licitações — one row per procurement PROCESSO (concluída or andamento).
--
-- Source: core_br_recife_licitacoes. economia = estimado − homologado (savings
-- vs the reference price) on concluídas. Feeds the contratos page's
-- procurement context (modalidade mix, savings, in-progress pipeline).
--
-- ⚠ Grain is one row per processo, NOT per lot — see the staging model header
-- for why (the source repeats the processo total on every lot row, which put a
-- 5.6× inflated R$ 103.9 bn on the site until 2026-07-25). n_lotes /
-- n_fornecedores carry the lot detail that the aggregation would otherwise
-- lose; razao_social is the winning supplier by lot value.
-- =============================================================================

WITH provenance AS (
    SELECT
        ANY_VALUE(dataset_title)     AS source_name,
        ANY_VALUE(dataset_page_url)  AS source_url,
        ANY_VALUE(portal_name)       AS source_portal,
        ANY_VALUE(license_title)     AS source_license,
        MAX(rows_updated_at)         AS rows_updated_at
    FROM {{ ref('core_br_recife_source_catalog') }}
    WHERE source_id LIKE 'licitacoes_%'
)

SELECT
    l.status,
    l.comissao,
    l.processo_numero,
    l.processo_ano,
    l.modalidade,
    l.orgao,
    l.objeto,
    l.doc,
    l.doc_tipo,
    l.razao_social,
    l.valor_estimado,
    l.valor_homologado,
    l.valor_lotes,
    l.n_lotes,
    l.n_fornecedores,
    l.economia,
    l.data_conclusao,
    'BRL'                            AS unit,
    p.source_name,
    p.source_url,
    p.source_portal,
    p.source_license,
    p.rows_updated_at                AS source_rows_updated_at
FROM {{ ref('core_br_recife_licitacoes') }} l
CROSS JOIN provenance p
