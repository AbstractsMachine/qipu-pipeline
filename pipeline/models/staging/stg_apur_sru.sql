{{ config(materialized='view', schema='staging', tags=['staging', 'logement']) }}

-- Inventaire SRU par arrondissement (APUR).
-- 2001-2019 : l'open data APUR (comptages bruts, résidences principales
-- comprises) — scripts/enrich/build_seed_apur_sru.py.
-- À partir de 2025 : la note annuelle « Les chiffres du logement social à
-- Paris » (carte par arrondissement), qui publie le nombre de logements et
-- la part, pas les résidences principales. Les 20 arrondissements somment
-- au total parisien de l'inventaire officiel (276 032 au 1er janvier 2025).

SELECT
    arrondissement,
    label,
    annee,
    logements_sociaux,
    residences_principales,
    CAST(NULL AS FLOAT64) AS taux_pct_publie,
    source,
    source_url,
    licence
FROM {{ ref('seed_apur_sru_2001_2019') }}

UNION ALL

SELECT
    arrondissement,
    label,
    annee,
    logements_sociaux,
    CAST(NULL AS INT64) AS residences_principales,
    taux_pct_publie,
    source,
    source_url,
    licence
FROM {{ ref('seed_apur_sru_publie') }}
