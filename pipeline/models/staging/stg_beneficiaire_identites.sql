-- Wrapper minimal du seed. Existe pour respecter la règle « tout seed
-- entre par stg ». Aucune transformation : les types et le contenu
-- proviennent de pipeline/seeds/seed_beneficiaire_identites.csv (column_types
-- déclarés dans dbt_project.yml), produit par
-- scripts/enrich/identites_beneficiaires.py.
--
-- Grain : une graphie normalisée (`beneficiaire_normalise`) → son identité
-- (`identite` = la graphie canonique de l'organisation). Seules les graphies
-- rapprochées y figurent ; une graphie absente est sa propre identité.

{{ config(materialized='view', schema='staging', tags=['staging','seed-wrapper']) }}

SELECT * FROM {{ ref('seed_beneficiaire_identites') }}
