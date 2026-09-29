-- =============================================================================
-- Mart: paying agency × year × recipient — the órgão ↔ credor bridge
--
-- Sources: core_br_recife_despesa (organisation rows only),
--          core_br_recife_credor (stable recipient name).
-- Grain:   orgao × ano × recipient_key (CNPJ).
--
-- Serves export_br_recife.py's órgão pages (per-year spend, top suppliers)
-- and the recipient fiche's by-agency breakdown — previously computed by the
-- export straight on the core (E4). Amounts = SUM(pago_liquido) of the
-- empenho rows; nome comes from the recipient dimension so the same CNPJ
-- carries one name everywhere.
-- =============================================================================

WITH org_rows AS (
    SELECT recipient_key, orgao, ano, pago_liquido
    FROM {{ ref('core_br_recife_despesa') }}
    WHERE is_org AND recipient_key IS NOT NULL AND orgao IS NOT NULL
)

SELECT
    r.orgao,
    r.ano,
    r.recipient_key,
    c.nome,
    SUM(r.pago_liquido)   AS pago,
    COUNT(*)              AS n_empenhos,
    'BRL'                 AS unit
FROM org_rows r
LEFT JOIN {{ ref('core_br_recife_credor') }} c ON c.cnpj = r.recipient_key
GROUP BY 1, 2, 3, 4
