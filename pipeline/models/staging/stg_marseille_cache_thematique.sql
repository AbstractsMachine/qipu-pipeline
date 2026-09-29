-- MIROIR PUBLIC — remplace le wrapper du dépôt privé (scripts/public-mirror/overlay).
--
-- Le cache seed_marseille_cache_thematique.csv n'est PAS publié : il est indexé
-- par nom de bénéficiaire, et la liste source des subventions de Marseille
-- contient des particuliers. Le contrôle pii_gate.py refuse ce chemin. Ce modèle
-- garde les mêmes colonnes et les mêmes types, avec zéro ligne :
-- core_marseille_subventions le lit en LEFT JOIN et retombe sur
-- 'Non classifié' / 'default'.

{{ config(materialized='view', schema='staging', tags=['staging', 'seed-wrapper', 'marseille', 'public-mirror-stub']) }}

SELECT
    CAST(NULL AS STRING)  AS beneficiaire_normalise,
    CAST(NULL AS STRING)  AS ode_thematique,
    CAST(NULL AS STRING)  AS ode_sous_categorie,
    CAST(NULL AS FLOAT64) AS ode_confiance,
    CAST(NULL AS STRING)  AS ode_source
LIMIT 0
