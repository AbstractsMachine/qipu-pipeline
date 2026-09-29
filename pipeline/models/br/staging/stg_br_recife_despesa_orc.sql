-- =============================================================================
-- Staging: Despesas orçamentárias 2002-2023 — the older series, typed.
--
-- Sources: raw.br_recife_despesa_orc_{2002..2023} (all strings, same 39
--          columns every year — header md5-checked 2026-09-23).
-- Grain:   one row per empenho movement (empenho × subempenho × month).
--
-- What this series has that the 2024+ files split apart: função/subfunção,
-- categoria/grupo/ELEMENTO (the natureza — « sob que forma ») and órgão on
-- the same row. What it lacks: the credor's CPF/CNPJ. credor_codigo is the
-- City's internal 8-digit code (Caixa = 04500018, not its CNPJ root), so
-- this series is NEVER joined to the 2024+ recipients, and credor names are
-- not exposed (persons are paid here too, with no document to tell them apart).
-- Amounts are ','-decimal from 2016 ("16229,00") and '.'-decimal before
-- ("16229.00") — br_amount() handles both.
--
-- SOURCE TRAP (checked 2026-09-23): the portal's « 2002 » resource holds
-- 2022's movements (ano_movimentacao = 2022, R$ 6.33 bn paid), and its
-- « 2022 » resource holds 1 685 rows that pay nothing. There is no 2002 in
-- the series. The year is read from ano_movimentacao, never from the table
-- name, so 2022 is counted once and the series runs 2003-2023.
-- =============================================================================

{% set years = range(2002, 2024) %}

WITH unioned AS (
{% for y in years %}
    SELECT *, {{ y }} AS _src_year FROM {{ source('br_recife_raw', 'br_recife_despesa_orc_' ~ y) }}
    {% if not loop.last %}UNION ALL{% endif %}
{% endfor %}
)

SELECT
    {{ br_int('ano_movimentacao') }}               AS ano,
    {{ br_int('mes_movimentacao') }}               AS mes,
    {{ br_string('orgao_codigo') }}                AS orgao_codigo,
    {{ br_string('orgao_nome') }}                  AS orgao,
    {{ br_string('unidade_codigo') }}              AS unidade_codigo,
    {{ br_string('unidade_nome') }}                AS unidade,
    {{ br_string('categoria_economica_codigo') }}  AS categoria_codigo,
    {{ br_string('categoria_economica_nome') }}    AS categoria,
    {{ br_string('grupo_despesa_codigo') }}        AS grupo_codigo,
    {{ br_string('grupo_despesa_nome') }}          AS grupo,
    {{ br_string('modalidade_aplicacao_codigo') }} AS modalidade_aplicacao_codigo,
    {{ br_string('modalidade_aplicacao_nome') }}   AS modalidade_aplicacao,
    {{ br_string('elemento_codigo') }}             AS elemento_codigo,
    {{ br_string('elemento_nome') }}               AS elemento,
    {{ br_string('funcao_codigo') }}               AS funcao_codigo,
    {{ br_string('funcao_nome') }}                 AS funcao,
    {{ br_string('subfuncao_codigo') }}            AS subfuncao_codigo,
    {{ br_string('subfuncao_nome') }}              AS subfuncao,
    {{ br_string('programa_nome') }}               AS programa,
    {{ br_string('acao_nome') }}                   AS acao,
    {{ br_string('fonte_recurso_nome') }}          AS fonte,
    {{ br_string('modalidade_licitacao_nome') }}   AS modalidade_licitacao,
    {{ br_amount('valor_empenhado') }}             AS empenhado,
    {{ br_amount('valor_liquidado') }}             AS liquidado,
    {{ br_amount('valor_pago') }}                  AS pago,
    _src_year,
    _synced_at
FROM unioned
