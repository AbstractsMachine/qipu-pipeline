-- =============================================================================
-- Core: every município's contracts, one row each, with the município's
-- identity and the year the page files it under (signature year, else the
-- contract's own year). Clustered by município : the export reads one at a
-- time.
--
-- valor_suspeito (2026-09-22) : the PNCP carries typing errors that dwarf
-- everything else — a health credentialing call in Palmeiras de Goiás at
-- R$ 2 371 bi, 13 600 times the town's yearly spending ; with them, 2026's
-- municipal total read R$ 11 841 bi, without them R$ 218 bi. A flat ceiling
-- would drop real concessions (Palmas transport, Brusque sewerage, Porto
-- Alegre's PPP all sit at 0.2–2× their city's yearly spending). The rule is
-- relative : a contract worth more than 3× the município's largest yearly
-- paid spending (SICONFI, total line 3.00.000) is flagged ; without a
-- SICONFI figure, above R$ 1 bi. Flagged rows stay (the page can say one
-- was set aside) but never enter a sum or a ranking.
-- =============================================================================

{{ config(cluster_by=['id_municipio']) }}

WITH budget AS (
    SELECT id_municipio, MAX(pago) AS pago_max
    FROM {{ ref('core_br_municipio_despesas') }}
    WHERE funcao_codigo = '00' AND subfuncao_codigo = '000'
    GROUP BY id_municipio
),

base AS (
SELECT
    c.numero_controle_pncp,
    c.id_municipio,
    m.slug,
    m.nome AS municipio,
    c.uf,
    COALESCE(EXTRACT(YEAR FROM c.data_assinatura), c.ano_contrato) AS ano,
    c.ano_contrato,
    c.tipo_contrato,
    c.categoria_processo,
    c.objeto,
    c.valor_global,
    c.valor_inicial,
    c.data_assinatura,
    c.vigencia_inicio,
    c.vigencia_fim,
    c.data_publicacao,
    c.orgao_cnpj,
    c.orgao_nome,
    c.poder,
    c.unidade_codigo,
    c.unidade_nome,
    c.numero_contrato,
    c.fornecedor_ni,
    c.fornecedor_nome,
    c.fornecedor_tipo,
    c.receita,
    b.pago_max AS municipio_pago_max,
    CASE
        WHEN b.pago_max IS NOT NULL AND b.pago_max > 0 THEN c.valor_global > 3 * b.pago_max
        ELSE c.valor_global > 1e9
    END AS au_dela_du_budget
FROM {{ ref('stg_br_pncp_contratos') }} c
JOIN {{ ref('stg_br_municipios') }} m USING (id_municipio)
LEFT JOIN budget b USING (id_municipio)
),

-- Second rule, dominance : six vans in Teresina at R$ 1 685 mi pass the
-- budget rule (35 % of a large city's year) but weigh 31× the town's next
-- contract. A contract more than 10× the next one of its município and year,
-- and above 20 % of the yearly spending, is flagged — unless its objeto is a
-- concession, a PPP, a management contract or an urban service let for years
-- (Goiânia's street cleaning, Jundiaí's buses, Brusque's sewerage are real
-- and look exactly like that). Measured 2026-09-22 on the 2026 contracts.
dominance AS (
    SELECT
        numero_controle_pncp,
        valor_global / NULLIF(LEAD(valor_global) OVER (
            PARTITION BY id_municipio, ano ORDER BY valor_global DESC), 0) AS fois_le_suivant,
        ROW_NUMBER() OVER (PARTITION BY id_municipio, ano ORDER BY valor_global DESC) AS rk
    FROM base
    WHERE NOT au_dela_du_budget AND ano IS NOT NULL
)

SELECT
    base.* EXCEPT (au_dela_du_budget),
    base.au_dela_du_budget
      OR COALESCE(
           d.rk = 1
           AND d.fois_le_suivant > 10
           AND base.municipio_pago_max > 0
           AND base.valor_global > 0.2 * base.municipio_pago_max
           -- A concession, a PPP or a management contract is protected up to
           -- the budget rule (3×) : Palmas's buses, Brusque's sewerage sit at
           -- 1.5–1.6× a year. An urban service let for years is protected only
           -- up to one year's spending : Goiânia's street cleaning is 82 %, a
           -- truck rental « for waste collection » in Sertânia at 199 % is not.
           AND NOT REGEXP_CONTAINS(LOWER(base.objeto), r'concess|parceria p|ppp|contrato de gest')
           AND NOT (
                 REGEXP_CONTAINS(LOWER(base.objeto),
                   r'transporte (p[uú]blico|coletivo)|esgot|limpeza urbana|saneamento|ilumina[cç][aã]o p[uú]blica|coleta de (lixo|res[ií]duos)')
                 AND base.valor_global <= base.municipio_pago_max
               ),
           FALSE) AS valor_suspeito
FROM base
LEFT JOIN dominance d USING (numero_controle_pncp)
