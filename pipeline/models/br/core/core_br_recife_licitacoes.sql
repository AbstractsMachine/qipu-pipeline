-- =============================================================================
-- Core: Recife public tenders (licitações) — one row per processo
--
-- Source: stg_br_recife_licitacoes (concluídas + em andamento unified at the
--         processo grain; lot rows already collapsed there).
-- Grain:  (comissao, processo_numero, processo_ano).
-- =============================================================================

SELECT *
FROM {{ ref('stg_br_recife_licitacoes') }}
