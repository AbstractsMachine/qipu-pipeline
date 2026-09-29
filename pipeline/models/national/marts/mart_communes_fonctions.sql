{{
  config(
    enabled=true,
    materialized='table',
    partition_by={'field': 'annee', 'data_type': 'int64', 'range': {'start': 2010, 'end': 2051, 'interval': 1}},
    cluster_by=['code_insee'],
    tags=['national', 'marts']
  )
}}

/*
  Mart: à quoi sert l'argent des communes — cellules fonction × compte

  Grain : commune × exercice × référence fonctionnelle × compte. C'est la
  source de export_communes_fonctions.py, qui replie ces cellules en arbre
  (fonction → sous-fonction → nature, familles de nature), pose les libellés et
  les plafonds de lignes, et compare chaque commune à sa strate.

  Le périmètre, et pourquoi :
    - communes (categ « Commune », et « PARIS » qui a sa propre catégorie),
      budget principal (cbudg = 1), balance définitive ;
    - CLASSE 6 UNIQUEMENT : les comptes de classe 2 sont de l'investissement ;
      les additionner gonflait les totaux d'environ 20 % (Nemours 21,4 M€ au
      lieu des 17,8 M€ de sa maquette) ;
    - une référence fonctionnelle lisible (voir core) et un montant non nul ;
    - compartiment : la clé de fonction, sauf pour les reversements (« rev »),
      qui quittent leur fonction AVANT toute agrégation — natures, domaines et
      totaux les suivent. « nv » (non ventilable) reste sa propre clé.

  CORSE ET OUTRE-MER : incluses. L'ancien script recomposait leur code INSEE en
  « 02A004 » ou « 101101 », qui ne correspondaient à aucune commune et les
  écartaient sans le dire (128 communes en 2024, dont Ajaccio et Cayenne). Le
  staging recompose le bon code (« 2A004 », « 97101 »).

  montant : NUMERIC exact. premiere_ligne : le rang de la cellule dans le CSV
  source — l'export replie les cellules dans cet ordre, pour que ses sommes
  soient exactement celles des fichiers déjà publiés (en flottant, l'ordre
  d'addition décide de l'arrondi des montants qui tombent sur 50 centimes).

  nomenclature : la nomenclature dominante de la commune (celle qui porte le
  plus de dépenses ; ex aequo → la première rencontrée dans le fichier). Elle
  choisit les libellés M14 ou M57 à l'export.

  libelle_budget : le nom du budget tel que la DGFiP l'écrit (« AJACCIO »). Il
  sert à nommer, dans les avertissements de l'export, une commune du fichier
  que l'index des communes du site ne connaît pas.
*/

{{ fonctions_cellules("'Commune', 'PARIS'", 'code_insee') }}
