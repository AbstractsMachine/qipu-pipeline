-- =============================================================================
-- Mart : fraîcheur de chaque source Paris — ce que le site affiche
--
-- Grain : source_id (une ligne par dataset ODS du catalogue).
--
-- Réunit, pour l'export data_freshness.json et les surfaces qui le lisent
-- (/methode « Fraîcheur par source », dialogue Provenance, légendes
-- ChartSource, JSON-LD Dataset) : titre, page, licence, `published_by_city_at`
-- = quand la Ville a publié / mis à jour (rows_updated_at du portail),
-- `synced_at` = quand notre sync l'a relu.
--
-- Existe pour que l'export ne lise QUE des marts (layering E4) : avant le
-- 2026-09-09 il lisait core + staging directement, et le gardien du layering
-- a bloqué main.
--
-- Les colonnes d'années (year_min, year_max, complete_years, partial_years,
-- has_year_status) sont portées ici avec leur type définitif mais VIDES : elles
-- se remplissent quand mart_source_year_status (gate année partielle, PR #5)
-- est mergé — le mart fera alors la jointure, sans changer le contrat de
-- l'export. Vocabulaire côté site : « publié par la Ville le · mis à jour sur
-- Qipu le ».
-- =============================================================================

{{ config(materialized='table', schema='marts', tags=['marts', 'freshness', 'catalog']) }}

SELECT
    source_id,
    dataset_id,
    dataset_title,
    dataset_page_url,
    publisher,
    license_title,
    license_url,
    records_count,
    rows_updated_at                                               AS published_by_city_at,
    synced_at,
    CAST(NULL AS INT64)                                           AS year_min,
    CAST(NULL AS INT64)                                           AS year_max,
    CAST([] AS ARRAY<INT64>)                                      AS complete_years,
    CAST([] AS ARRAY<STRUCT<annee INT64, n_rows INT64, ratio FLOAT64>>) AS partial_years,
    FALSE                                                         AS has_year_status
FROM {{ ref('core_paris_source_catalog') }}
