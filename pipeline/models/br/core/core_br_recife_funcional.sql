-- =============================================================================
-- Core: Recife budget execution by function (despesa funcional programática)
--
-- Source: stg_br_recife_funcional (2024–2026 unified, typed).
-- Grain:  ano × mês × função × subfunção × programa × ação × fonte —
--         monthly INCREMENTAL movements (summing across months is correct;
--         mês=0 rows carry the opening dotação with pago=0).
-- =============================================================================

SELECT *
FROM {{ ref('stg_br_recife_funcional') }}
