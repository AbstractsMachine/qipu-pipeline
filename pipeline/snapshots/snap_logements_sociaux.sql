{#
  Snapshot : logements sociaux financés à Paris.
  Les agréments peuvent être révisés (nombre de logements final ≠
  agrément initial). Capture pour suivre l'évolution.

  Clé unique : id_livraison (colonnes raw courtes depuis la migration sync_ods_dataset).
#}
{% snapshot snap_logements_sociaux %}
{{
    config(
      target_schema='dbt_paris_snapshots',
      unique_key='id_livraison',
      strategy='check',
      check_cols=[
        'adresse_programme',
        'annee',
        'bs',
        'nb_logmt_total',
        'nb_plai',
        'nb_plus',
        'nb_pls',
        'mode_real',
        'nature_programme',
      ],
    )
}}
select * from {{ source('paris_raw', 'logements_sociaux_finances_a_paris') }}
where id_livraison is not null
{% endsnapshot %}
