{{ config(materialized='table', schema='analytics', tags=['core', 'logement']) }}

-- Taux SRU par arrondissement et par année (grain : arrondissement × année).
-- Le taux est dérivé ici des comptages bruts quand la source donne les
-- résidences principales (2001-2019) ; sinon c'est le taux publié par l'APUR.

SELECT
    arrondissement,
    label,
    annee,
    logements_sociaux,
    residences_principales,
    COALESCE(
        taux_pct_publie,
        ROUND(100.0 * logements_sociaux / NULLIF(residences_principales, 0), 1)
    ) AS taux_sru_pct,
    source,
    source_url,
    licence
FROM {{ ref('stg_apur_sru') }}
WHERE residences_principales > 0 OR taux_pct_publie IS NOT NULL
