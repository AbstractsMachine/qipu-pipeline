-- =============================================================================
-- Mart: the budget page of every município — função and subfunção rows with
-- their names, flagged (is_total, is_funcao), pago / empenhado / liquidado.
-- Grain: ano × município × conta. Export: export_br_municipios.py.
-- =============================================================================

{{ config(cluster_by=['id_municipio']) }}

WITH d AS (
    SELECT * FROM {{ ref('core_br_municipio_despesas') }}
),
funcoes AS (
    SELECT ano, id_municipio, funcao_codigo, conta AS funcao
    FROM d
    WHERE subfuncao_codigo = '000' AND funcao_codigo != '00'
)

SELECT
    d.ano,
    d.id_municipio,
    d.sigla_uf,
    d.funcao_codigo,
    f.funcao,
    d.subfuncao_codigo,
    IF(d.subfuncao_codigo = '000', NULL, d.conta) AS subfuncao,
    d.funcao_codigo = '00'      AS is_total,
    d.subfuncao_codigo = '000'  AS is_funcao,
    d.pago,
    d.empenhado,
    d.liquidado
FROM d
LEFT JOIN funcoes f USING (ano, id_municipio, funcao_codigo)
