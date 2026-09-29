{{ config(tags=['referential_integrity']) }}
{# Identité des bénéficiaires (seed_beneficiaire_identites, 2026-09-29).
   Échoue si :
   - une graphie rapprochée porte une ligne « Personnes physiques » (on ne
     rapproche jamais des particuliers) ;
   - une identité ne figure pas elle-même dans le seed (chaîne cassée : la
     graphie canonique doit être sa propre identité) ;
   - le regroupement du mart change le total d'un exercice (regrouper ne
     change aucune somme, au centime). #}
WITH pp AS (
    SELECT 'personne_physique_rapprochee' AS defaut, beneficiaire_normalise AS cle
    FROM {{ ref('core_subventions') }}
    WHERE ode_nom_identite IS NOT NULL
      AND nature_juridique = 'Personnes physiques'
),
chaine AS (
    SELECT 'identite_absente_du_seed' AS defaut, s.identite AS cle
    FROM {{ ref('stg_beneficiaire_identites') }} s
    LEFT JOIN {{ ref('stg_beneficiaire_identites') }} c
      ON c.beneficiaire_normalise = s.identite AND c.identite = s.identite
    WHERE c.beneficiaire_normalise IS NULL
),
core_an AS (
    SELECT annee, SUM(CAST(ROUND(montant * 100) AS INT64)) AS c
    FROM {{ ref('core_subventions') }}
    WHERE donnees_disponibles = TRUE AND montant > 0
    GROUP BY annee
),
mart_an AS (
    SELECT annee, SUM(CAST(ROUND(montant_total * 100) AS INT64)) AS c
    FROM {{ ref('mart_subventions_beneficiaires') }}
    GROUP BY annee
),
totaux AS (
    SELECT 'total_annuel_modifie' AS defaut, CAST(annee AS STRING) AS cle
    FROM core_an FULL JOIN mart_an USING (annee)
    WHERE ABS(COALESCE(core_an.c, 0) - COALESCE(mart_an.c, 0)) > 1
)
SELECT * FROM pp
UNION ALL SELECT * FROM chaine
UNION ALL SELECT * FROM totaux
