-- =============================================================================
-- Core: Contratos — row-level OBT, one row per contract.
--
-- contrato_id = URL-safe id derived from numero_contrato ("2901.0339/2004"
-- has a slash) so the fiche route can key off it. recipient_key = the CNPJ
-- for org contractors (NULL for CPF individuals — never exposed by identity).
--
-- ⚠ numero_contrato is NOT unique in the source (audited 2026-07-25):
--   - 53 rows carry the literal placeholder "Aguardando Numeração" (two case
--     variants) for contracts the portal has not numbered yet — they all
--     slugify to `aguardando-numera-o`;
--   - a handful of real numbers are genuinely repeated (e.g. 3901.4002/2024).
-- Left as-is, every colliding contract resolves to the SAME fiche route and
-- any join on contrato_id silently conflates them. We keep the readable slug
-- when it is unique and append a short deterministic hash of the row's
-- identifying fields when it is not, so ids stay stable across rebuilds.
-- =============================================================================

WITH base AS (
    SELECT
        *,
        REGEXP_REPLACE(LOWER(numero_contrato), r'[^a-z0-9]+', '-') AS slug_base
    FROM {{ ref('stg_br_recife_contratos') }}
    WHERE numero_contrato IS NOT NULL
),

disambiguated AS (
    SELECT
        *,
        COUNT(*) OVER (PARTITION BY slug_base) AS slug_n,
        SUBSTR(TO_HEX(SHA256(CONCAT(
            IFNULL(orgao_contratante, ''), '|',
            IFNULL(CAST(ano_contrato AS STRING), ''), '|',
            IFNULL(doc, ''), '|',
            IFNULL(objeto, ''), '|',
            IFNULL(CAST(valor_contrato AS STRING), ''), '|',
            IFNULL(CAST(vigencia_inicio AS STRING), '')
        ))), 1, 8) AS slug_hash
    FROM base
)

SELECT
    numero_contrato,
    -- NULL for placeholder rows so the UI can say "sem número" rather than
    -- printing "Aguardando Numeração" as if it were a contract reference.
    IF(REGEXP_CONTAINS(LOWER(numero_contrato), r'aguardando'), NULL, numero_contrato)
                            AS numero_contrato_publicavel,
    IF(slug_n = 1, slug_base, CONCAT(slug_base, '-', slug_hash))
                            AS contrato_id,
    -- The register leaves the year empty on 2 129 contracts whose number still
    -- ends with it (« 1401.0272/2003 »): read it there (2026-09-23), so they
    -- reach the yearly charts. A year outside 1990-2030 is not a year.
    COALESCE(
        ano_contrato,
        (SELECT y FROM UNNEST([SAFE_CAST(REGEXP_EXTRACT(numero_contrato, r'/\s*((?:19|20)\d{2})\s*$') AS INT64)]) y WHERE y BETWEEN 1990 AND 2030)
    )                       AS ano_contrato,
    ano_contrato IS NULL    AS ano_do_numero,
    orgao_contratante,
    objeto,
    modalidade,
    doc,
    doc_tipo,
    is_org,
    IF(is_org, doc, NULL)   AS recipient_key,
    razao_social,
    bairro,
    cidade,
    uf,
    vigencia_inicio,
    vigencia_fim,
    valor_contrato,
    valor_contrato_2,
    situacao
FROM disambiguated
