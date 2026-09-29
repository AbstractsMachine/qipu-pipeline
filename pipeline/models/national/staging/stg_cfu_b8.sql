{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}
/*
  Staging: subventions nominatives des communes (annexe B8 / B1.7), une ligne
  par bénéficiaire. Les lignes de total et de sous-total imprimées dans
  l'annexe sont écartées ici (elles servent au contrôle, pas à l'affichage).

  Vie privée, deuxième garde (la première est dans l'extraction) : aucune
  catégorie « personne physique », aucun nom qui commence par une civilité.
*/
SELECT
    CAST(code_insee AS STRING)          AS code_insee,
    CAST(doc_type AS STRING)            AS doc_type,
    CAST(annee AS INT64)                AS annee,
    CAST(source_url AS STRING)          AS source_url,
    CAST(rang AS INT64)                 AS rang,
    TRIM(CAST(nom AS STRING))           AS nom,
    CAST(numeraire AS FLOAT64)          AS numeraire,
    NULLIF(TRIM(CAST(nature AS STRING)), '') AS nature,
    CAST(categorie AS STRING)           AS categorie
FROM {{ source('national_raw', 'cfu_b8_lignes') }}
WHERE COALESCE(type_ligne, 'ligne') = 'ligne'
  AND nom IS NOT NULL AND TRIM(nom) != ''
  AND NOT REGEXP_CONTAINS(LOWER(COALESCE(categorie, '')), r'physique')
  AND NOT REGEXP_CONTAINS(UPPER(TRIM(nom)), r'^(M\.|MME\b|MLLE\b|MONSIEUR\b|MADAME\b|MR\b)')
  -- Lignes mal découpées à l'extraction : le nom a avalé la description d'une
  -- aide en nature (« … (agents+véhicules+matériels) ») ou deux lignes collées.
  AND NOT REGEXP_CONTAINS(LOWER(nom), r'agents\s*\+|\+\s*v[ée]hicules|mat[ée]riels\)')
  AND LENGTH(TRIM(nom)) <= 110
