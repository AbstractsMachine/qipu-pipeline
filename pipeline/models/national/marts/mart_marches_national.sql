{{
  config(
    enabled=true,
    materialized='table',
    tags=['national', 'marts']
  )
}}

/*
  Mart: marchés publics national (source d'export, row-level)

  Une ligne = 1 marché attribué à une commune. L'exporteur
  (export_marches_national.py) lit ces lignes filtrées par code_insee et agrège
  (total, par année, top titulaires, par catégorie CPV, couverture).
*/

SELECT
    code_insee,
    commune_nom,
    population,
    annee,
    -- La DATE, pas seulement l'année : sans elle, impossible de savoir ce qui est
    -- nouveau depuis la dernière visite, et donc impossible de notifier. Le core
    -- la portait déjà ; c'est ce mart qui la jetait.
    date_notification,
    montant,
    categorie_cpv,
    cpv_division,
    type_procedure,
    objet,
    titulaire_nom,
    titulaire_siren,
    titulaire_personne_physique,
    montant_invraisemblable,
    depenses_totales_commune,
    marche_id,
    duree_mois,
    -- Le détail de la fiche contrat (2026-09-13).
    nature_marche,
    forme_prix,
    offres_recues,
    ccag,
    techniques,
    considerations_sociales,
    considerations_environnementales,
    sous_traitance_declaree,
    lieu_execution_code,
    lieu_execution_type,
    id_accord_cadre,
    nb_titulaires,
    nb_modifications
FROM {{ ref('core_marches_national') }}
WHERE montant > 0
