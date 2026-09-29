-- =============================================================================
-- Mart: civic places (facilities directory) — one row per geolocated facility.
--
-- Identity/geo only (Phase 1). Money-on-map (contract/obra crosswalk) is a
-- later enrichment. Feeds the shared PlacesExplorer via the Recife adapter.
-- Slug is readable + unique (suffixed only on name collision).
-- =============================================================================

SELECT
    slug,
    nome,
    familia,
    tipo,
    lat,
    lon,
    bairro,
    endereco,
    detalhe,
    ode_obras_total,
    ode_n_obras,
    'Dados Abertos da Prefeitura do Recife'                      AS source_name,
    'https://dados.recife.pe.gov.br/dataset?tags=Equipamentos'  AS source_url,
    'BRL'                                                        AS unit
FROM {{ ref('core_br_recife_places') }}
