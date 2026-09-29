-- MIROIR PUBLIC — remplace le wrapper du dépôt privé (scripts/public-mirror/overlay).
--
-- Le cache seed_cache_thematique_beneficiaires.csv n'est PAS publié : il est
-- indexé par nom de bénéficiaire, et la liste source des subventions contient
-- des particuliers. Le contrôle pii_gate.py refuse ce chemin. Ce modèle garde
-- donc les mêmes colonnes et les mêmes types, avec zéro ligne : core_subventions
-- et dim_beneficiaire le lisent en LEFT JOIN, la thématique retombe sur la
-- cascade aval (motif → direction → catégorie → 'Non classifié').

{{ config(materialized='view', schema='staging', tags=['staging','seed-wrapper','public-mirror-stub']) }}

SELECT
    CAST(NULL AS STRING)  AS beneficiaire_normalise,
    CAST(NULL AS STRING)  AS ode_thematique,
    CAST(NULL AS STRING)  AS ode_sous_categorie,
    CAST(NULL AS FLOAT64) AS ode_confiance,
    CAST(NULL AS STRING)  AS ode_date_recherche,
    CAST(NULL AS STRING)  AS ode_source
LIMIT 0
