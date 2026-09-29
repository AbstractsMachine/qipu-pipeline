{{
  config(
    enabled=true,
    materialized='table',
    tags=['national', 'marts']
  )
}}

/*
  Mart: les taux votés par la commune (taxe foncière), toutes années REI,
  avec la médiane de sa strate de population (même strates que le comparateur
  OFGL) pour la dernière année. Une ligne par commune × année.
*/

WITH t AS (
    SELECT r.*, o.population
    FROM {{ ref('stg_rei_taux') }} r
    LEFT JOIN (
        SELECT code_insee, population
        FROM {{ ref('stg_ofgl_communes') }}
        QUALIFY ROW_NUMBER() OVER (PARTITION BY code_insee ORDER BY annee DESC) = 1
    ) o USING (code_insee)
),

strates AS (
    SELECT
        annee,
        CASE
            WHEN population < 100 THEN 0 WHEN population < 200 THEN 1 WHEN population < 500 THEN 2
            WHEN population < 1000 THEN 3 WHEN population < 2000 THEN 4 WHEN population < 3500 THEN 5
            WHEN population < 5000 THEN 6 WHEN population < 10000 THEN 7 WHEN population < 20000 THEN 8
            WHEN population < 50000 THEN 9 WHEN population < 100000 THEN 10 ELSE 11
        END AS strate,
        APPROX_QUANTILES(tfb_commune, 2)[OFFSET(1)] AS tfb_commune_mediane
    FROM t
    WHERE population IS NOT NULL AND tfb_commune IS NOT NULL
    GROUP BY 1, 2
)

SELECT
    t.code_insee,
    t.commune_nom,
    t.annee,
    t.tfb_commune,
    t.tfb_commune_vote,
    t.tfb_epci,
    t.tfnb_commune,
    t.nom_epci,
    s.tfb_commune_mediane
FROM t
LEFT JOIN strates s
  ON s.annee = t.annee
 AND s.strate = CASE
            WHEN t.population < 100 THEN 0 WHEN t.population < 200 THEN 1 WHEN t.population < 500 THEN 2
            WHEN t.population < 1000 THEN 3 WHEN t.population < 2000 THEN 4 WHEN t.population < 3500 THEN 5
            WHEN t.population < 5000 THEN 6 WHEN t.population < 10000 THEN 7 WHEN t.population < 20000 THEN 8
            WHEN t.population < 50000 THEN 9 WHEN t.population < 100000 THEN 10 ELSE 11
        END
