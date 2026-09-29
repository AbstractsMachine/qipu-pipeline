-- =============================================================================
-- Mart: the revenue side of every município's budget page — the total, the
-- origens (level 2 : impostos, transferências correntes, operações de
-- crédito…) and their detail (level 3 : impostos, taxas…), gross, deductions
-- and net. Grain: ano × município × conta. Export: export_br_municipios.py.
-- =============================================================================

{{ config(cluster_by=['id_municipio']) }}

SELECT
    r.ano,
    r.id_municipio,
    r.sigla_uf,
    r.id_conta_bd,
    r.conta,
    r.nivel,
    r.grupo_codigo,
    r.origem_codigo,
    r.detalhe_codigo,
    r.nivel = 0 AS is_total,
    r.nivel = 1 AS is_grupo,
    r.nivel = 2 AS is_origem,
    r.nivel = 3 AS is_detalhe,
    r.bruta,
    r.deducao_fundeb,
    r.deducoes,
    r.liquida
FROM {{ ref('core_br_municipio_receitas') }} r
WHERE r.nivel <= 3
