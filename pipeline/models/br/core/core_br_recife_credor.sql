-- =============================================================================
-- Core: Recife recipient (credor) — one row per organisation CNPJ
--
-- Sources: core_br_recife_despesa (name), int_br_recife_credor_ano (latest
--          principal agency), stg_br_recife_enrich_cnpj (Receita Federal
--          registry: razão social, CNAE, porte…), stg_br_recife_enrich_vulgar
--          (plain-language summary), stg_br_recife_tema_map (CNAE-section /
--          agency-regex → citizen theme — mapping seed).
-- Grain:  cnpj (recipient_key of is_org rows).
--
-- Enrichment columns are prefixed ode_ (they are ours, not the source's).
-- ode_tema: CNAE-section mapping first, else the agency regex mapping on the
-- latest year's principal agency, else 'Outros'. When several regexes match,
-- the lowest prioridade wins (Gestão pública is the catch-all at prioridade 3,
-- the specific themes sit at 2); remaining ties are broken alphabetically by
-- theme so the result is stable build to build.
-- Every amount stays in the row-level core / int; this is a dimension.
-- =============================================================================

WITH org_rows AS (
    SELECT recipient_key AS cnpj, nome_credor
    FROM {{ ref('core_br_recife_despesa') }}
    WHERE is_org AND recipient_key IS NOT NULL
),

name_counts AS (
    SELECT cnpj, nome_credor, COUNT(*) AS n
    FROM org_rows
    WHERE nome_credor IS NOT NULL
    GROUP BY 1, 2
),

names AS (
    SELECT
        cnpj,
        ARRAY_AGG(nome_credor ORDER BY n DESC, nome_credor LIMIT 1)[OFFSET(0)] AS nome
    FROM name_counts
    GROUP BY cnpj
),

recipients AS (
    SELECT
        recipient_key AS cnpj,
        ARRAY_AGG(principal_orgao IGNORE NULLS ORDER BY ano DESC LIMIT 1)[SAFE_OFFSET(0)]
                                                  AS principal_orgao
    FROM {{ ref('int_br_recife_credor_ano') }}
    GROUP BY recipient_key
),

cnpj AS (
    SELECT * FROM {{ ref('stg_br_recife_enrich_cnpj') }}
),

vulgar AS (
    SELECT * FROM {{ ref('stg_br_recife_enrich_vulgar') }}
),

tema_cnae AS (
    SELECT r.cnpj, m.tema
    FROM recipients r
    JOIN cnpj c ON c.cnpj = r.cnpj
    JOIN {{ ref('stg_br_recife_tema_map') }} m
        ON m.chave_tipo = 'cnae_secao' AND m.chave = c.cnae_secao
),

tema_orgao AS (
    SELECT cnpj, ARRAY_AGG(tema ORDER BY prioridade, tema LIMIT 1)[OFFSET(0)] AS tema
    FROM (
        SELECT r.cnpj, m.tema, m.prioridade
        FROM recipients r
        JOIN {{ ref('stg_br_recife_tema_map') }} m
            ON m.chave_tipo = 'orgao_regex'
            AND r.principal_orgao IS NOT NULL
            -- the legal-form suffix "- ADMINISTRAÇÃO SUPERVISIONADA" / "- ADM.
            -- SUPERVISIONADA" is not a domain: stripped before matching so it
            -- cannot trigger the "administra" catch-all of Gestão pública.
            AND REGEXP_CONTAINS(
                REGEXP_REPLACE(r.principal_orgao, r'(?i)\s*[-–]\s*ADM(INISTRA[ÇC][ÃA]O)?\.?\s+SUPERVISIONADA\s*$', ''),
                m.chave)
    )
    GROUP BY cnpj
)

SELECT
    r.cnpj,
    n.nome,
    r.principal_orgao,
    c.razao_social_oficial      AS ode_razao_social,
    c.cnae_codigo               AS ode_cnae_codigo,
    c.cnae_descricao            AS ode_cnae_descricao,
    c.cnae_secao                AS ode_cnae_secao,
    c.porte                     AS ode_porte,
    c.natureza_juridica         AS ode_natureza_juridica,
    c.situacao                  AS ode_situacao,
    c.municipio                 AS ode_municipio,
    c.uf                        AS ode_uf,
    COALESCE(tc.tema, to_.tema, 'Outros')  AS ode_tema,
    CASE
        WHEN tc.tema IS NOT NULL THEN 'cnae'
        WHEN to_.tema IS NOT NULL THEN 'orgao'
        ELSE 'default'
    END                         AS ode_tema_fonte,
    v.resumo                    AS ode_resumo,
    v.o_que_financia            AS ode_o_que_financia,
    v.model                     AS ode_resumo_model
FROM recipients r
LEFT JOIN names n        ON n.cnpj = r.cnpj
LEFT JOIN cnpj c         ON c.cnpj = r.cnpj
LEFT JOIN vulgar v       ON v.cnpj = r.cnpj
LEFT JOIN tema_cnae tc   ON tc.cnpj = r.cnpj
LEFT JOIN tema_orgao to_ ON to_.cnpj = r.cnpj
