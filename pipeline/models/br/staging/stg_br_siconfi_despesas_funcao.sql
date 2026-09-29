-- =============================================================================
-- Staging: SICONFI DCA Anexo I-E, every município — despesas por função e
-- subfunção, by stage (2026-09-18, the Brazilian long tail).
--
-- Source: raw.br_siconfi_despesas_funcao — a filtered copy of the Base dos
--         Dados mirror basedosdados.br_me_siconfi.municipio_despesas_funcao
--         (US region ; copied to EU by scripts/sync/sync_br_siconfi.py). Coverage measured 2026-09-18:
--         2017→2024 = 5 538–5 564 municípios each year, 2025 = 5 446.
-- Grain:  ano × município × estágio × conta.
-- Codes:  id_conta_bd = '3.FF.SSS' — FF the função (04 Administração, 10
--         Saúde, 12 Educação…), SSS the subfunção ; SSS = 000 is the função's
--         own total, FF = 00 the grand total ("Despesas Exceto
--         Intraorçamentárias"). Rows without a code (intraorçamentárias) are
--         left out : the total the page shows excludes them, as SICONFI does.
-- =============================================================================

SELECT
    ano,
    id_municipio,
    sigla_uf,
    estagio,
    id_conta_bd,
    conta_bd,
    SPLIT(id_conta_bd, '.')[SAFE_OFFSET(1)] AS funcao_codigo,
    SPLIT(id_conta_bd, '.')[SAFE_OFFSET(2)] AS subfuncao_codigo,
    valor
FROM {{ source('br_siconfi_raw', 'br_siconfi_despesas_funcao') }}
WHERE ano >= 2017
  AND id_conta_bd IS NOT NULL AND id_conta_bd != ''
  AND valor IS NOT NULL
  AND estagio IN ('Despesas Empenhadas', 'Despesas Liquidadas', 'Despesas Pagas')
