{{
  config(
    enabled=true,
    materialized='view',
    tags=['national', 'staging']
  )
}}

/*
  Staging: DECP marchés publics (national, ungated)

  Source = decp.parquet consolidé (data.gouv.fr), une ligne par marché×titulaire.
  On rattache chaque marché à la COMMUNE acheteuse par SIREN (9 premiers chiffres
  de acheteur_id) joint à l'univers OFGL — donc uniquement les marchés dont
  l'acheteur est une commune, attribués à son INSEE.

  Nettoyage et déduplication : stg_decp_marches_acheteurs (tous les acheteurs,
  2026-09-26) ; ici, les seuls acheteurs communes. Déduplication : une ligne par marché (acheteur × id) pour ne pas compter le
  montant plusieurs fois quand un marché a plusieurs titulaires ou plusieurs
  modifications (avenants) — deux pièges classiques du DECP. On garde la
  version en cours (donneesActuelles, puis la dernière modification), et le
  titulaire au plus gros montant comme titulaire principal.

  Dimension commune : UNE ligne par SIREN (dernier exercice OFGL). L'ancien
  SELECT DISTINCT incluait la population, qui change chaque année → chaque
  marché était multiplié par le nombre d'exercices (×7 : Lyon affichait
  37 331 marchés pour 5 703 réels).

  ⚠ Couverture DECP : ~50-70 % au national (seuil de publication 40 k€ HT). On
  l'AFFICHE (nb marchés, montant), sans prétendre à l'exhaustivité.
*/

WITH d AS (
    SELECT * FROM {{ ref('stg_decp_marches_acheteurs') }}
),

-- Une ligne par commune (dernier exercice OFGL), jamais une par année.
commune_dim AS (
    SELECT siren, code_insee, commune_nom, dep_name, reg_name, population
    FROM {{ ref('stg_ofgl_communes') }}
    QUALIFY ROW_NUMBER() OVER (PARTITION BY siren ORDER BY annee DESC) = 1
)

SELECT
    d.marche_id,
    c.code_insee,
    c.commune_nom,
    c.dep_name,
    c.reg_name,
    c.population,
    d.acheteur_siren,
    d.acheteur_nom,
    d.objet,
    d.nature_marche,
    d.type_procedure,
    d.code_cpv,
    d.cpv_division,
    d.montant,
    d.forme_prix,
    d.date_notification,
    d.annee,
    d.duree_mois,
    d.titulaire_nom,
    d.titulaire_siret,
    d.titulaire_siren,
    d.offres_recues,
    d.ccag,
    d.techniques,
    d.considerations_sociales,
    d.considerations_environnementales,
    d.sous_traitance_declaree,
    d.lieu_execution_code,
    d.lieu_execution_type,
    d.id_accord_cadre,
    d.nb_titulaires,
    d.nb_modifications
FROM d
INNER JOIN commune_dim c
    ON d.acheteur_siren = c.siren
