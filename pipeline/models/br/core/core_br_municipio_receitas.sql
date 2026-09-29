-- =============================================================================
-- Core: receitas orçamentárias, every município, the gross and the deductions
-- side by side and their difference (the net revenue SICONFI calls "receita
-- realizada"). One row per ano × município × conta. Clustered by município :
-- the export reads one município at a time.
-- =============================================================================

{{ config(cluster_by=['id_municipio']) }}

SELECT
    ano,
    id_municipio,
    sigla_uf,
    id_conta_bd,
    ANY_VALUE(conta_bd) AS conta,
    ANY_VALUE(nivel) AS nivel,
    ANY_VALUE(grupo_codigo) AS grupo_codigo,
    ANY_VALUE(origem_codigo) AS origem_codigo,
    ANY_VALUE(detalhe_codigo) AS detalhe_codigo,
    SUM(IF(estagio = 'Receitas Brutas Realizadas', valor, 0)) AS bruta,
    SUM(IF(estagio = 'Deduções - FUNDEB', valor, 0)) AS deducao_fundeb,
    SUM(IF(estagio != 'Receitas Brutas Realizadas', valor, 0)) AS deducoes,
    SUM(IF(estagio = 'Receitas Brutas Realizadas', valor, 0))
      - SUM(IF(estagio != 'Receitas Brutas Realizadas', valor, 0)) AS liquida
FROM {{ ref('stg_br_siconfi_receitas') }}
GROUP BY 1, 2, 3, 4
