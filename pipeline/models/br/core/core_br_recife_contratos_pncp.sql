-- =============================================================================
-- Core: the contracts Recife's executive bodies publish on the PNCP
-- (core_br_municipio_contratos, id_municipio 2611606 — the Câmara (poder L)
-- is left out, as the city's own register leaves it out; the município itself
-- is published with poder N, « não se aplica », its autarquias with E), keyed for the join
-- with that register (core_br_recife_contratos).
--
-- Why: the city's register stopped publishing amounts after 2021 (0 of 769
-- contracts in 2025 carry one); the PNCP carries them. numero_chave writes the
-- PNCP number the way the city does: « 5011.0023 » of 2025 → « 5011.0023/2025 ».
-- Revenue contracts (receita) are not purchases and stay out.
-- =============================================================================

SELECT
    numero_controle_pncp,
    ano,
    ano_contrato,
    numero_contrato,
    CONCAT(REGEXP_REPLACE(UPPER(TRIM(numero_contrato)), r'\s*/\s*\d{4}$', ''), '/', CAST(ano_contrato AS STRING)) AS numero_chave,
    tipo_contrato,
    categoria_processo,
    objeto,
    valor_global,
    valor_suspeito,
    data_assinatura,
    vigencia_inicio,
    vigencia_fim,
    data_publicacao,
    orgao_cnpj,
    orgao_nome,
    unidade_codigo,
    unidade_nome,
    fornecedor_ni,
    fornecedor_nome,
    fornecedor_tipo
FROM {{ ref('core_br_municipio_contratos') }}
WHERE id_municipio = '2611606'
  AND COALESCE(poder, '') NOT IN ('L', 'J')
  AND NOT COALESCE(receita, FALSE)
  AND numero_contrato IS NOT NULL
