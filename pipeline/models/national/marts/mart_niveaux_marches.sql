{{
  config(
    enabled=true,
    materialized='table',
    cluster_by=['siren'],
    tags=['national', 'marts']
  )
}}

/*
  Mart : les marchés publics des régions, départements et intercommunalités
  (2026-09-26, échelle des niveaux) — « À qui va l'argent » de leur page.

  Une ligne = un marché (stg_decp_marches_acheteurs : un par acheteur × id)
  dont l'acheteur est une collectivité de niveau (son SIREN, dernière année des
  comptes OFGL), notifié depuis 2019. Mesuré le 2026-09-26 : en 2025, 3 901
  marchés de régions, 14 525 de départements, 38 723 d'intercommunalités.

  Deux protections, comme pour les communes :
    - titulaire_personne_physique : un entrepreneur individuel (Sirene) n'est
      jamais nommé sur le site ;
    - montant_invraisemblable : un accord-cadre publie son plafond, parfois plus
      grand que toutes les dépenses de l'année de la collectivité (les marchés
      des régions « totalisaient » plus que leurs budgets ; Toulouse Métropole :
      816 M€ pour 12 mois de travaux, 67 % de ses dépenses). Au-dessus du quart
      des dépenses totales de l'année, le montant est gardé mais jamais
      additionné (0,6 % des marchés depuis 2023, mesuré le 2026-09-26) ;
    - doublon_probable : la même publication sous un autre identifiant ;
    - plafond_repete : le plafond d'un programme recopié sur chacun de ses lots.
*/

WITH niveaux AS (
    SELECT niveau, siren, depenses_totales
    FROM {{ ref('mart_niveaux_reperes') }}
    WHERE TRUE
    QUALIFY annee = MAX(annee) OVER (PARTITION BY niveau)
),

-- Un SIREN, une collectivité : la Métropole de Lyon est à la fois département et
-- intercommunalité dans l'OFGL ; ses marchés vont à sa page, celle du département.
niveaux_un AS (
    SELECT * FROM niveaux
    QUALIFY ROW_NUMBER() OVER (PARTITION BY siren ORDER BY IF(niveau = 'departement', 0, IF(niveau = 'region', 1, 2))) = 1
),

sirene AS (
    SELECT siren, est_personne_physique
    FROM {{ ref('stg_sirene_unites_legales') }}
)

SELECT
    n.niveau,
    m.acheteur_siren                         AS siren,
    m.marche_id,
    m.annee,
    m.date_notification,
    m.objet,
    m.nature_marche,
    m.type_procedure,
    m.cpv_division,
    m.montant,
    m.duree_mois,
    m.titulaire_siren,
    COALESCE(s.est_personne_physique, FALSE)  AS titulaire_personne_physique,
    IF(COALESCE(s.est_personne_physique, FALSE), NULL, m.titulaire_nom) AS titulaire_nom,
    m.nb_titulaires,
    m.id_accord_cadre,
    -- Ce que la fiche contrat et la fiche fournisseur montrent, comme pour une commune
    -- (export_territoires_marches.py réutilise la construction des communes).
    {{ categorie_cpv('m.cpv_division', 'm.code_cpv') }} AS categorie_cpv,
    m.forme_prix,
    m.offres_recues,
    m.ccag,
    m.techniques,
    m.considerations_sociales,
    m.considerations_environnementales,
    m.sous_traitance_declaree,
    m.lieu_execution_code,
    m.lieu_execution_type,
    m.nb_modifications,
    n.depenses_totales,
    (n.depenses_totales IS NOT NULL AND m.montant > 0.25 * n.depenses_totales) AS montant_invraisemblable,
    -- Le même accord-cadre republié sous d'autres identifiants (« 2024M0188 »,
    -- « 24M0188 », « 2024M018800 » : 6 fois 116 M€ chez Toulouse Métropole) : même
    -- titulaire, même montant, même année → une seule fois dans les sommes.
    ROW_NUMBER() OVER (
        PARTITION BY m.acheteur_siren, COALESCE(m.titulaire_siren, m.titulaire_nom), CAST(ROUND(m.montant * 100) AS INT64), m.annee
        ORDER BY m.date_notification, m.marche_id
    ) > 1 AS doublon_probable,
    -- Un plafond de programme recopié sur chaque lot (audit 26/09 : la région Hauts-de-France
    -- publie les lots de son programme de formation 2025 avec 800 M€ chacun, 76 Md€ « signés »
    -- dans l'année) : le même montant d'au moins 1 M€ sur trois marchés ou plus du même
    -- acheteur la même année n'est jamais additionné ni attribué à un titulaire.
    (m.montant >= 1000000 AND COUNT(*) OVER (
        PARTITION BY m.acheteur_siren, m.annee, CAST(ROUND(m.montant) AS INT64)
    ) >= 3) AS plafond_repete
FROM {{ ref('stg_decp_marches_acheteurs') }} m
JOIN niveaux_un n ON n.siren = m.acheteur_siren
LEFT JOIN sirene s ON s.siren = m.titulaire_siren
WHERE m.annee >= 2019
