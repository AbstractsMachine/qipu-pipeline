-- =============================================================================
-- Intermediate: Recife recipients × year — organisations only
--
-- Source: core_br_recife_despesa (is_org rows with a recipient_key).
-- Grain:  recipient_key (CNPJ) × ano.
--
-- principal_orgao = the paying agency with the most empenho rows that year.
-- Ties are broken by agency name (alphabetical) so the value is stable from
-- one build to the next — the previous APPROX_TOP_COUNT pick was not.
-- =============================================================================

WITH org_rows AS (
    SELECT * FROM {{ ref('core_br_recife_despesa') }}
    WHERE is_org AND recipient_key IS NOT NULL
),

orgao_counts AS (
    SELECT recipient_key, ano, orgao, COUNT(*) AS n
    FROM org_rows
    WHERE orgao IS NOT NULL
    GROUP BY 1, 2, 3
),

principal AS (
    SELECT
        recipient_key,
        ano,
        ARRAY_AGG(orgao ORDER BY n DESC, orgao LIMIT 1)[OFFSET(0)] AS principal_orgao
    FROM orgao_counts
    GROUP BY 1, 2
),

by_year AS (
    SELECT
        recipient_key,
        ano,
        COUNT(*)                                     AS n_empenhos,
        SUM(pago_liquido)                            AS total_pago,
        SUM(empenhado)                               AS total_empenhado,
        SUM(IF(is_subvencao, pago_liquido, 0))       AS subvencao_pago,
        LOGICAL_OR(is_subvencao)                     AS is_subvencao_any,
        COUNT(DISTINCT orgao)                        AS n_orgaos
    FROM org_rows
    GROUP BY 1, 2
)

SELECT
    y.recipient_key,
    y.ano,
    y.n_empenhos,
    y.total_pago,
    y.total_empenhado,
    y.subvencao_pago,
    y.is_subvencao_any,
    y.n_orgaos,
    p.principal_orgao
FROM by_year y
LEFT JOIN principal p USING (recipient_key, ano)
