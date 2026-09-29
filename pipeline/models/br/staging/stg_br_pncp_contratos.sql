-- =============================================================================
-- Staging: the contracts of the municípios on the PNCP (2026-09-18).
--
-- Source: raw.br_pncp_contratos — the /v1/contratos feed by publication day,
--         municipal rows only (scripts/sync/sync_br_pncp.py) — and
--         raw.br_pncp_contratos_orgaos, the per-body backfill of earlier years
--         (scripts/sync/sync_br_pncp_orgaos.py, Recife's bodies 2021-2025).
--         A contract is republished when it is rectified, and may sit in both
--         tables : keep its latest publication.
-- Grain:  one row per contract (numero_controle_pncp).
-- Kept:   real contracts with a positive amount ; « Empenho » rows (spending
--         commitments some states publish here) are not contracts.
-- =============================================================================

WITH src AS (
    SELECT
        numero_controle_pncp,
        sequencial,
        numero_retificacao,
        ano_contrato,
        numero_contrato,
        tipo_contrato,
        categoria_processo,
        objeto,
        valor_inicial,
        valor_global,
        SAFE_CAST(data_assinatura AS DATE)                              AS data_assinatura,
        SAFE_CAST(vigencia_inicio AS DATE)                              AS vigencia_inicio,
        SAFE_CAST(vigencia_fim AS DATE)                                 AS vigencia_fim,
        SAFE_CAST(SUBSTR(data_publicacao, 1, 10) AS DATE)               AS data_publicacao,
        SAFE_CAST(SUBSTR(data_atualizacao_global, 1, 19) AS DATETIME)   AS data_atualizacao_global,
        orgao_cnpj,
        orgao_nome,
        poder,
        unidade_codigo,
        unidade_nome,
        id_municipio,
        municipio_nome,
        uf,
        fornecedor_ni,
        fornecedor_nome,
        fornecedor_tipo,
        receita
    FROM (
        SELECT * FROM {{ source('br_pncp_raw', 'br_pncp_contratos') }}
        UNION ALL
        SELECT * FROM {{ source('br_pncp_raw', 'br_pncp_contratos_orgaos') }}
    )
    WHERE esfera = 'M'
      AND numero_controle_pncp IS NOT NULL
      AND id_municipio IS NOT NULL
      AND tipo_contrato != 'Empenho'
      AND valor_global IS NOT NULL AND valor_global > 0
)

SELECT * EXCEPT (rn)
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY numero_controle_pncp ORDER BY data_atualizacao_global DESC, numero_retificacao DESC) AS rn
    FROM src
)
WHERE rn = 1
