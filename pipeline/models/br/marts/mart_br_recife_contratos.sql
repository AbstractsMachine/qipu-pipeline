-- =============================================================================
-- Mart: Contratos — one row per contract, with provenance.
--
-- Source: core_br_recife_contratos. Exposes org contractors by name; CPF
-- individuals keep doc_tipo='cpf' with razao_social masked downstream (the
-- exporter/fiche renders "pessoa física" instead of the name). is_ativo
-- flags contracts whose vigência covers today AND whose situação is not
-- cancelled/closed (date alone let 3 CANCELADO/ENCERRADO rows read as live).
--
-- valor_implausivel — plausibility guard on the source amount (added
-- 2026-07-25). The portal publishes at least one contract whose stated value
-- exceeds the ENTIRE annual municipal budget: 3101.1007/2023 (ARIES) carries
-- R$ 15.3 bn against a ~R$ 9.2 bn/yr budget, while the payments actually
-- recorded against that CNPJ are ~R$ 2.8 M (2024) and ~R$ 3.5 M (2025). A
-- single contract worth more than everything the city commits in a year
-- cannot be taken at face value, so we flag it rather than silently ranking
-- on it. The ceiling is DERIVED from the budget data (no hardcoded constant),
-- so it travels to other years and cities. Flagged rows are kept and shown —
-- with the amount suppressed and the reason stated — never deleted.
--
-- PNCP (added 2026-09-23). The city's register stopped publishing amounts
-- after 2021 (0 of 769 contracts in 2025 carry one); the national registry
-- (core_br_recife_contratos_pncp) carries them. Two things happen here:
--   1. a city contract with NO amount takes the PNCP amount of the SAME
--      contract — matched on the number (« 5011.0023/2025 ») with the same
--      supplier when both name one, else on supplier + start date; a match
--      must be one-to-one or it is dropped. A city amount is never replaced.
--   2. PNCP contracts the city register does not list are added, with
--      fonte = 'pncp' and contrato_id « pncp-<control number> ». They have no
--      modalidade (the PNCP carries it on the purchase, not the contract).
-- valor_fonte says where each row's amount comes from ('recife' | 'pncp').
--
-- a_receber (2026-09-23): the few « contracts » in which the CITY RECEIVES
-- the amount — an auction selling the right to a judicial credit (R$ 443 mi,
-- 2025), an onerous concession (public clocks, R$ 213 mi, 2022), onerous
-- permits to use public space. They are not purchases: their amount is kept
-- but out of every spending total and ranking (export _val), and the fiche
-- says the city receives it. Narrow on purpose: « cessão de uso » of machines
-- the city rents stays a purchase.
-- =============================================================================

WITH provenance AS (
    SELECT
        ANY_VALUE(dataset_title)     AS source_name,
        ANY_VALUE(dataset_page_url)  AS source_url,
        ANY_VALUE(portal_name)       AS source_portal,
        ANY_VALUE(license_title)     AS source_license,
        MAX(rows_updated_at)         AS rows_updated_at
    FROM {{ ref('core_br_recife_source_catalog') }}
    WHERE source_id = 'contratos'
),

teto AS (
    SELECT MAX(empenhado_ano) AS teto_anual
    FROM (
        SELECT ano, SUM(empenhado) AS empenhado_ano
        FROM {{ ref('core_br_recife_funcional') }}
        GROUP BY ano
    )
),

city AS (
    SELECT * FROM {{ ref('core_br_recife_contratos') }}
),

pncp AS (
    SELECT * FROM {{ ref('core_br_recife_contratos_pncp') }}
),

-- 1a. Same number, and the same supplier when both sides name one.
m_numero AS (
    SELECT c.contrato_id, p.numero_controle_pncp
    FROM city c
    JOIN pncp p
      ON UPPER(TRIM(c.numero_contrato_publicavel)) = p.numero_chave
     AND (c.doc IS NULL OR p.fornecedor_ni IS NULL OR c.doc = p.fornecedor_ni)
    WHERE c.valor_contrato IS NULL
    QUALIFY COUNT(*) OVER (PARTITION BY c.contrato_id) = 1
        AND COUNT(*) OVER (PARTITION BY p.numero_controle_pncp) = 1
),

-- 1b. Otherwise the same supplier starting the same day.
m_fornecedor AS (
    SELECT c.contrato_id, p.numero_controle_pncp
    FROM city c
    JOIN pncp p
      ON c.doc = p.fornecedor_ni
     AND c.vigencia_inicio = p.vigencia_inicio
    WHERE c.valor_contrato IS NULL
      AND c.contrato_id NOT IN (SELECT contrato_id FROM m_numero)
      AND p.numero_controle_pncp NOT IN (SELECT numero_controle_pncp FROM m_numero)
    QUALIFY COUNT(*) OVER (PARTITION BY c.contrato_id) = 1
        AND COUNT(*) OVER (PARTITION BY p.numero_controle_pncp) = 1
),

matched AS (
    SELECT * FROM m_numero
    UNION ALL
    SELECT * FROM m_fornecedor
),

city_rows AS (
    SELECT
        c.contrato_id,
        c.numero_contrato,
        c.numero_contrato_publicavel,
        c.ano_contrato,
        c.orgao_contratante,
        c.objeto,
        c.modalidade,
        c.doc,
        c.doc_tipo,
        c.is_org,
        c.razao_social,
        c.cidade,
        c.uf,
        c.vigencia_inicio,
        c.vigencia_fim,
        COALESCE(c.valor_contrato, CAST(p.valor_global AS NUMERIC)) AS valor_contrato,
        c.valor_contrato_2,
        c.situacao,
        'recife'                                            AS fonte,
        CASE WHEN c.valor_contrato IS NOT NULL THEN 'recife'
             WHEN p.valor_global IS NOT NULL THEN 'pncp' END AS valor_fonte,
        p.numero_controle_pncp,
        COALESCE(p.valor_suspeito, FALSE) AND c.valor_contrato IS NULL AS pncp_suspeito
    FROM city c
    LEFT JOIN matched m USING (contrato_id)
    LEFT JOIN pncp p ON p.numero_controle_pncp = m.numero_controle_pncp
),

pncp_rows AS (
    SELECT
        CONCAT('pncp-', REGEXP_REPLACE(LOWER(p.numero_controle_pncp), r'[^a-z0-9]+', '-')) AS contrato_id,
        p.numero_chave                                      AS numero_contrato,
        p.numero_chave                                      AS numero_contrato_publicavel,
        p.ano                                               AS ano_contrato,
        -- The paying unit when it names a secretaria, else the body.
        IF(p.unidade_nome IS NULL OR REGEXP_CONTAINS(UPPER(p.unidade_nome), r'UNIDADE [ÚU]NICA'),
           p.orgao_nome, p.unidade_nome)                    AS orgao_contratante,
        p.objeto,
        CAST(NULL AS STRING)                                AS modalidade,
        p.fornecedor_ni                                     AS doc,
        CASE p.fornecedor_tipo WHEN 'PJ' THEN 'cnpj' WHEN 'PF' THEN 'cpf' ELSE 'outro' END AS doc_tipo,
        p.fornecedor_tipo = 'PJ'                            AS is_org,
        p.fornecedor_nome                                   AS razao_social,
        CAST(NULL AS STRING)                                AS cidade,
        CAST(NULL AS STRING)                                AS uf,
        p.vigencia_inicio,
        p.vigencia_fim,
        CAST(p.valor_global AS NUMERIC)                     AS valor_contrato,
        CAST(NULL AS NUMERIC)                               AS valor_contrato_2,
        CAST(NULL AS STRING)                                AS situacao,
        'pncp'                                              AS fonte,
        'pncp'                                              AS valor_fonte,
        p.numero_controle_pncp,
        COALESCE(p.valor_suspeito, FALSE)                   AS pncp_suspeito
    FROM pncp p
    WHERE p.numero_controle_pncp NOT IN (SELECT numero_controle_pncp FROM matched)
),

unioned AS (
    SELECT * FROM city_rows
    UNION ALL
    SELECT * FROM pncp_rows
)

SELECT
    u.* EXCEPT (pncp_suspeito),
    (u.vigencia_inicio IS NOT NULL
        AND u.vigencia_inicio <= CURRENT_DATE()
        AND (u.vigencia_fim IS NULL OR u.vigencia_fim >= CURRENT_DATE())
        AND COALESCE(u.situacao, '') NOT IN ('CANCELADO', 'ENCERRADO')
    )                                AS is_ativo,
    ((u.valor_contrato IS NOT NULL AND u.valor_contrato > t.teto_anual) OR u.pncp_suspeito)
                                     AS valor_implausivel,
    REGEXP_CONTAINS(UPPER(COALESCE(u.objeto, '')),
        r'^\s*LEIL[AÃ]O|CESS[AÃ]O ONEROSA|PERMISS[AÃ]O DE USO\s*ONEROSA|CONCESS[AÃ]O ONEROSA|OUTORGA ONEROSA')
                                     AS a_receber,
    t.teto_anual                     AS valor_teto_plausibilidade,
    'BRL'                            AS unit,
    p.source_name,
    p.source_url,
    p.source_portal,
    p.source_license,
    p.rows_updated_at                AS source_rows_updated_at
FROM unioned u
CROSS JOIN provenance p
CROSS JOIN teto t
