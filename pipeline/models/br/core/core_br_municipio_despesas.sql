-- =============================================================================
-- Core: despesas por função e subfunção, every município, the three stages
-- side by side (pago, empenhado, liquidado). One row per ano × município ×
-- conta. Clustered by município : the export reads one município at a time.
-- =============================================================================

{{ config(cluster_by=['id_municipio']) }}

SELECT
    ano,
    id_municipio,
    sigla_uf,
    funcao_codigo,
    subfuncao_codigo,
    ANY_VALUE(conta_bd) AS conta,
    SUM(IF(estagio = 'Despesas Pagas', valor, 0))       AS pago,
    SUM(IF(estagio = 'Despesas Empenhadas', valor, 0))  AS empenhado,
    SUM(IF(estagio = 'Despesas Liquidadas', valor, 0))  AS liquidado
FROM {{ ref('stg_br_siconfi_despesas_funcao') }}
GROUP BY 1, 2, 3, 4, 5
