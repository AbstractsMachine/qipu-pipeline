{{
  config(
    enabled=true,
    materialized='table',
    cluster_by=['code_insee'],
    tags=['national', 'core']
  )
}}
/*
  Core: subventions nominatives des communes — une ligne par ligne d'annexe
  (un bénéficiaire peut en avoir plusieurs : deux objets, une régularisation
  négative). Le montant en argent (`numeraire`) et, à part, l'aide en nature
  décrite (salle, matériel, personnel mis à disposition) : l'annexe les
  distingue, la page aussi.
*/
SELECT
    code_insee,
    doc_type,
    annee,
    source_url,
    rang,
    nom,
    COALESCE(numeraire, 0)            AS montant,
    nature                            AS aide_nature,
    categorie,
    CASE
        WHEN REGEXP_CONTAINS(LOWER(COALESCE(categorie, '')), r'association') THEN 'association'
        WHEN REGEXP_CONTAINS(LOWER(COALESCE(categorie, '')), r'public|commune|ccas|établissement|etablissement|syndicat|epci') THEN 'public'
        WHEN REGEXP_CONTAINS(LOWER(COALESCE(categorie, '')), r'priv') THEN 'prive'
        ELSE 'autre'
    END                               AS type_beneficiaire
FROM {{ ref('stg_cfu_b8') }}
