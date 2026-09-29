{#
  La catégorie d'achat d'un marché (division CPV → thème) : une correspondance déterministe,
  publique. Une seule définition pour les communes (core_marches_national) et les niveaux
  (mart_niveaux_marches, 2026-09-26), pour qu'un fournisseur soit rangé pareil partout.

  Division 50 (« services de réparation et d'entretien ») : on lit le groupe (3 chiffres),
  parce que la division mêle l'entretien des véhicules et celui des bâtiments. Rangée en bloc
  dans « Transport », elle y mettait l'exploitation du chauffage de Lille et l'entretien des
  pompes et des bornes-fontaines de Nîmes (constaté le 2026-09-28).
    501, 502  véhicules, avions, navires, trains → Transport
    503       matériel de bureau, informatique, télécoms → Informatique
    504       matériel médical et de précision → Santé
    505, 507  pompes, vannes, tuyauteries ; installations des bâtiments (chauffage,
              ventilation, ascenseurs, électricité) → Construction & Bâtiment
    reste de 50 → Autres
#}
{% macro categorie_cpv(division, code_cpv=none) -%}
    CASE
        {%- if code_cpv is not none %}
        WHEN {{ division }} = '50' THEN
            CASE
                WHEN LEFT({{ code_cpv }}, 3) IN ('501', '502') THEN 'Transport & Véhicules'
                WHEN LEFT({{ code_cpv }}, 3) = '503' THEN 'Informatique & Télécom'
                WHEN LEFT({{ code_cpv }}, 3) = '504' THEN 'Santé & Social'
                WHEN LEFT({{ code_cpv }}, 3) IN ('505', '507') THEN 'Construction & Bâtiment'
                ELSE 'Autres'
            END
        {%- endif %}
        WHEN {{ division }} IN ('09', '31', '65') THEN 'Énergie'
        WHEN {{ division }} IN ('30', '32', '48', '72') THEN 'Informatique & Télécom'
        WHEN {{ division }} IN ('33', '85') THEN 'Santé & Social'
        WHEN {{ division }} IN ('34', '50', '60', '63') THEN 'Transport & Véhicules'
        WHEN {{ division }} IN ('39', '44', '45') THEN 'Construction & Bâtiment'
        WHEN {{ division }} IN ('55', '15', '03') THEN 'Alimentation & Restauration'
        WHEN {{ division }} IN ('71', '79') THEN 'Services professionnels'
        WHEN {{ division }} IN ('77', '90') THEN 'Environnement & Propreté'
        WHEN {{ division }} IN ('22', '80') THEN 'Éducation & Formation'
        WHEN {{ division }} = '92' THEN 'Culture & Loisirs'
        WHEN {{ division }} = '75' THEN 'Administration publique'
        ELSE 'Autres'
    END
{%- endmacro %}
