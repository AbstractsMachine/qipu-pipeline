{{
  config(
    enabled=true,
    materialized='table',
    cluster_by=['niveau', 'siren'],
    tags=['national', 'marts']
  )
}}

/*
  Mart : les repères de chaque région, département et intercommunalité, par
  exercice (2026-09-26, échelle des niveaux) — la source de
  export_territoires.py, comme mart_communes_reperes l'est de l'index des
  communes.

  Une ligne = collectivité × exercice. Pour chaque agrégat : le montant
  consolidé (budget principal + annexes, flux croisés retirés) et les euros
  par habitant que publie l'OFGL. Un agrégat qu'un niveau n'a pas (le RSA pour
  une intercommunalité, la DGF pour une région depuis 2018) reste NULL : la
  page n'affiche pas la ligne.
*/

{#
  « D'où vient l'argent » : impots_taxes + concours_etat + subventions_recues + ventes
  + autres_recettes_fonct = les recettes de fonctionnement au centime (Haute-Garonne,
  Occitanie, Toulouse Métropole 2025, mesuré le 2026-09-26) ; avec
  recettes_invest_hors_emprunts et emprunts, les recettes totales. tva, ticpe, tsca,
  dmto, cartes_grises : le détail des impôts d'un département ou d'une région.
#}
{% set agregats = [
    ('depenses_fonctionnement', "Dépenses de fonctionnement"),
    ('depenses_investissement', "Dépenses d'investissement hors remb"),
    ('depenses_totales',        "Dépenses totales hors remb"),
    ('depenses_equipement',     "Dépenses d'équipement"),
    ('recettes_fonctionnement', "Recettes de fonctionnement"),
    ('recettes_totales',        "Recettes totales hors emprunts"),
    ('epargne_brute',           "Epargne brute"),
    ('encours_dette',           "Encours de dette"),
    ('annuite_dette',           "Annuité de la dette"),
    ('frais_personnel',         "Frais de personnel"),
    ('impots_locaux',           "Impôts locaux"),
    ('dgf',                     "Dotation globale de fonctionnement"),
    ('fiscalite_reversee',      "Fiscalité reversée"),
    ('subventions_droit_prive', "Subventions aux personnes de droit privé"),
    ('allocations_rsa',         "Allocations RSA"),
    ('allocations_apa',         "Allocations APA"),
    ('allocations_pch',         "Allocations PCH"),
    ('contributions_sdis',      "Contributions aux SDIS"),
    ('impots_taxes',            "Impôts et taxes"),
    ('concours_etat',           "Concours de l'Etat"),
    ('subventions_recues',      "Subventions reçues et participations"),
    ('ventes',                  "Ventes de biens et services"),
    ('autres_recettes_fonct',   "Autres recettes de fonctionnement"),
    ('recettes_invest_hors_emprunts', "Recettes d'investissement hors emprunts"),
    ('emprunts',                "Emprunts hors GAD"),
    ('tva',                     "TVA"),
    ('ticpe',                   "TICPE"),
    ('tsca',                    "TSCA"),
    ('dmto',                    "DMTO après péreq."),
    ('cartes_grises',           "Cartes grises"),
    ('subv_equipement_versees', "Subventions d'équipement versées"),
    ('remboursements_emprunts', "Remboursements d'emprunts hors GAD"),
] %}

SELECT
    n.niveau,
    n.annee,
    n.siren,
    ANY_VALUE(n.code)    AS code,
    ANY_VALUE(nom)       AS nom,
    ANY_VALUE(type)      AS type,
    ANY_VALUE(dep_code)  AS dep_code,
    ANY_VALUE(dep_name)  AS dep_name,
    ANY_VALUE(reg_code)  AS reg_code,
    ANY_VALUE(reg_name)  AS reg_name,
    ANY_VALUE(tranche)   AS tranche,
    ANY_VALUE(statut)    AS statut,
    ANY_VALUE(outre_mer) AS outre_mer,
    MAX(population)      AS population,
    {%- for col, label in agregats %}
    MAX(IF(agregat = "{{ label }}", montant, NULL))            AS {{ col }},
    MAX(IF(agregat = "{{ label }}", euros_par_habitant, NULL)) AS {{ col }}_hab,
    -- Le budget principal seul : le périmètre des dépenses par politique (DGFiP, cbudg 1),
    -- pour que « D'où vient l'argent » parle des mêmes comptes qu'elles.
    MAX(IF(agregat = "{{ label }}", montant_bp, NULL))         AS {{ col }}_bp,
    {%- endfor %}
    -- L'article du nom (Insee, code officiel géographique) : « de la Haute-Garonne ».
    ANY_VALUE(a.tncc)    AS tncc
FROM {{ ref('stg_ofgl_niveaux') }} n
LEFT JOIN {{ ref('seed_cog_articles') }} a
  ON a.niveau = n.niveau AND a.code = n.code
GROUP BY n.niveau, n.annee, n.siren
