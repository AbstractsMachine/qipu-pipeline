-- =============================================================================
-- Mart: what the município page shows of its contracts — the year's count
-- and total, and the largest contracts of the year (rank ≤ 20), objeto,
-- supplier, paying unit, amount. Grain: município × ano × contract, ranked.
--
-- Three things never enter a count, a sum or a ranking (2026-09-22) :
--   • a flagged amount (valor_suspeito, see core) — n_suspeitos says how many
--     were set aside ;
--   • a revenue contract (receita : the município sells or receives, it does
--     not spend) ;
--   • the same framework ceiling counted once per participant. A
--     credenciamento publishes one contract per supplier, each carrying the
--     whole call's ceiling : Lages counted its R$ 68 mi call a dozen times,
--     R$ 14.6 bi of the 2026 total came from such repeats. Same buyer, same
--     objeto, same amount = one line, with the number of suppliers on it.
-- =============================================================================

{{ config(cluster_by=['id_municipio']) }}

WITH kept AS (
    SELECT *
    FROM {{ ref('core_br_municipio_contratos') }}
    WHERE ano IS NOT NULL
      AND NOT valor_suspeito
      AND NOT COALESCE(receita, FALSE)
),

grouped AS (
    SELECT
        id_municipio,
        ano,
        orgao_cnpj,
        objeto,
        valor_global,
        COUNT(*) AS n_fornecedores,
        ARRAY_AGG(STRUCT(
            numero_controle_pncp, slug, tipo_contrato, categoria_processo,
            data_assinatura, vigencia_inicio, vigencia_fim, orgao_nome, unidade_nome,
            fornecedor_nome, fornecedor_tipo, numero_contrato,
            -- A private person's CPF never leaves this layer; a company keeps its CNPJ.
            IF(fornecedor_tipo = 'PJ', fornecedor_ni, NULL) AS fornecedor_cnpj
        ) ORDER BY data_assinatura, numero_controle_pncp LIMIT 1)[OFFSET(0)] AS r
    FROM kept
    GROUP BY id_municipio, ano, orgao_cnpj, objeto, valor_global
),

ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY id_municipio, ano ORDER BY valor_global DESC, r.numero_controle_pncp) AS rank_ano,
        COUNT(*)          OVER (PARTITION BY id_municipio, ano) AS n_ano,
        SUM(valor_global) OVER (PARTITION BY id_municipio, ano) AS valor_ano
    FROM grouped
),

suspeitos AS (
    SELECT id_municipio, ano, COUNT(*) AS n_suspeitos
    FROM {{ ref('core_br_municipio_contratos') }}
    WHERE ano IS NOT NULL AND valor_suspeito
    GROUP BY 1, 2
)

SELECT
    ranked.id_municipio,
    ranked.r.slug                   AS slug,
    ranked.ano,
    ranked.n_ano,
    ranked.valor_ano,
    ranked.rank_ano,
    ranked.r.numero_controle_pncp   AS numero_controle_pncp,
    ranked.r.tipo_contrato          AS tipo_contrato,
    ranked.r.categoria_processo     AS categoria_processo,
    ranked.objeto,
    ranked.valor_global,
    ranked.r.data_assinatura        AS data_assinatura,
    ranked.r.vigencia_inicio        AS vigencia_inicio,
    ranked.r.vigencia_fim           AS vigencia_fim,
    ranked.r.numero_contrato        AS numero_contrato,
    ranked.r.fornecedor_cnpj        AS fornecedor_cnpj,
    ranked.r.orgao_nome             AS orgao_nome,
    ranked.r.unidade_nome           AS unidade_nome,
    ranked.r.fornecedor_nome        AS fornecedor_nome,
    ranked.r.fornecedor_tipo        AS fornecedor_tipo,
    ranked.n_fornecedores,
    COALESCE(s.n_suspeitos, 0)      AS n_suspeitos,
    'BRL' AS unit,
    'https://pncp.gov.br/app/contratos' AS source_url
FROM ranked
LEFT JOIN suspeitos s USING (id_municipio, ano)
-- Every contract (2026-09-23): each one has its page (/brasil/<slug>/contrato/…),
-- not only the 20 largest. The page still shows the 12 largest.
