-- =============================================================================
-- Staging: dette-garantie (annexe IV-B emprunts garantis Paris)
--
-- Source: raw.dette_garantie_paris (chargé par pipeline/scripts/sync/sync_dette_garantie.py)
-- Grain: une ligne par emprunt garanti × annee_de_publication
--
-- Transformations:
--   - Renommage en snake_case court
--   - SAFE_CAST des numériques
--   - Filtre qualité: collectivite = 'Ville de Paris'
--   - source_url n'est plus écrit ici : core_dette_garantie le prend dans
--     core_paris_source_catalog (snapshot du catalogue ODS)
-- =============================================================================

{{ config(materialized='view', schema='staging', tags=['staging','hors_bilan']) }}

SELECT
    SAFE_CAST(annee_de_publication AS INT64) AS annee,
    collectivite,
    nature,
    SAFE_CAST(annee_de_mobilisation AS INT64) AS annee_mobilisation,
    profil_d_amort_de_l_emprunt AS profil_amort,
    designation_du_beneficiaire AS beneficiaire,
    objet_de_l_emprunt_garanti AS objet,
    organisme_preteur_ou_chef_de_file AS preteur,
    SAFE_CAST(montant_initial AS FLOAT64) AS montant_initial,
    SAFE_CAST(capital_restant_du_au_31_12_de_l_annee_de_publication AS FLOAT64) AS capital_restant,
    SAFE_CAST(duree_residuelle AS FLOAT64) AS duree_residuelle,
    periodicite_des_remboursements AS periodicite,
    taux_initial_taux AS taux_type,
    taux_initial_index AS taux_index,
    SAFE_CAST(taux_initial_taux_actuariel AS FLOAT64) AS taux_actuariel,
    SAFE_CAST(annuite_garantie_au_cours_de_l_exercice_en_interets AS FLOAT64) AS annuite_interets,
    SAFE_CAST(annuite_garantie_au_cours_de_l_exercice_en_capital AS FLOAT64) AS annuite_capital
FROM {{ source('paris_raw', 'dette_garantie_paris') }}
WHERE collectivite = 'Ville de Paris'
