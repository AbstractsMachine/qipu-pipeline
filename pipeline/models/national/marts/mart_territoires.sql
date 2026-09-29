{{
  config(
    enabled=true,
    materialized='table',
    tags=['national', 'marts']
  )
}}

/*
  Mart : l'échelle des niveaux — chaque commune et les collectivités dont elle
  fait partie (2026-09-26).

  Une ligne = une commune de la dernière composition intercommunale publiée par
  l'OFGL (ofgl_compositions : 35 004 communes en 2025, toutes rattachées à une
  intercommunalité). Pour chacune : son intercommunalité (SIREN, nom, nature
  juridique), son département et sa région (code, nom, SIREN de la
  collectivité), tels que les donne la dernière année des comptes OFGL.

  Les SIREN du département et de la région viennent de stg_ofgl_niveaux (la
  dernière année de chaque collectivité) : ce sont les clés des pages de
  niveau. Cas particuliers (mesurés le 2026-09-26) : 4 îles sans
  intercommunalité (« NA » dans la source) ; Bas-Rhin et Haut-Rhin → la
  Collectivité européenne d'Alsace (67A) ; les communes de la Métropole de Lyon
  → la Métropole (ML), celles du reste du Rhône → le Rhône ; Corse,
  Martinique, Guyane : pas de département, la collectivité unique est rangée
  avec les régions ; Mayotte : un département sans région ; Paris : commune et
  département à la fois.
*/

WITH compo AS (
    SELECT
        SAFE_CAST(annee AS INT64)  AS annee_composition,
        CASE
            WHEN SAFE_CAST(insee AS INT64) IS NOT NULL
                THEN LPAD(CAST(SAFE_CAST(insee AS INT64) AS STRING), 5, '0')
            ELSE CAST(insee AS STRING)
        END                        AS code_insee,
        CAST(siren AS STRING)      AS siren_commune,
        nom                        AS commune_nom,
        ptot                       AS population,
        -- Les îles sans intercommunalité (Bréhat, Ouessant, Sein…) portent « NA ».
        NULLIF(NULLIF(CAST(siren_epci AS STRING), 'NA'), '') AS siren_epci,
        IF(NULLIF(CAST(siren_epci AS STRING), 'NA') IS NULL, NULL, nom_epci) AS epci_nom
    FROM {{ source('national_raw', 'ofgl_compositions') }}
),

-- Petite couronne : une commune est dans un établissement public territorial
-- (EPT) ET dans la Métropole du Grand Paris (MET75) — deux lignes dans la source
-- pour 129 communes (mesuré le 2026-09-26). Son intercommunalité est l'EPT ; la
-- Métropole est gardée à part (siren_metropole_grand_paris).
mgp AS (
    SELECT DISTINCT siren FROM {{ ref('stg_ofgl_niveaux') }}
    WHERE niveau = 'epci' AND type = 'MET75'
),
compo_une AS (
    SELECT
        compo.* EXCEPT (siren_epci, epci_nom),
        ARRAY_AGG(IF(compo.siren_epci IN (SELECT siren FROM mgp), NULL, STRUCT(compo.siren_epci AS siren, compo.epci_nom AS nom)) IGNORE NULLS LIMIT 1)[SAFE_OFFSET(0)] AS epci,
        MAX(IF(compo.siren_epci IN (SELECT siren FROM mgp), compo.siren_epci, NULL)) AS siren_metropole_grand_paris
    FROM compo
    GROUP BY annee_composition, code_insee, siren_commune, commune_nom, population
),

-- Le département et la région de chaque commune : dernière année des comptes.
communes AS (
    SELECT code_insee, dep_code, dep_name, reg_code, reg_name
    FROM {{ ref('stg_ofgl_communes') }}
    WHERE TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY code_insee ORDER BY annee DESC) = 1
),

-- Les collectivités de la DERNIÈRE année de chaque niveau seulement : un
-- département disparu (Corse-du-Sud en 2017, Bas-Rhin en 2020) ne doit pas
-- recevoir les communes d'aujourd'hui.
dernier AS (
    SELECT niveau, siren, code, nom, type, reg_code
    FROM {{ ref('stg_ofgl_niveaux') }}
    WHERE TRUE
    QUALIFY annee = MAX(annee) OVER (PARTITION BY niveau)
        AND ROW_NUMBER() OVER (PARTITION BY niveau, siren ORDER BY annee DESC) = 1
),

epci AS (SELECT siren, type FROM dernier WHERE niveau = 'epci'),
dep AS (
    SELECT code, siren, nom, type
    FROM dernier WHERE niveau = 'departement' AND type = 'DEPT'
),
-- La Métropole de Lyon est à la fois l'intercommunalité et le « département »
-- de ses communes : même SIREN dans les deux bases OFGL.
ml AS (SELECT siren FROM dernier WHERE niveau = 'departement' AND type = 'ML'),
reg AS (
    SELECT code, siren, nom
    FROM dernier WHERE niveau = 'region'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY code ORDER BY siren) = 1
)

SELECT
    compo.annee_composition,
    compo.code_insee,
    compo.siren_commune,
    compo.commune_nom,
    compo.population,
    -- Les îles : ni EPT ni intercommunalité, et pas de Métropole → NULL.
    COALESCE(compo.epci.siren, compo.siren_metropole_grand_paris) AS siren_epci,
    IF(compo.epci.siren IS NULL AND compo.siren_metropole_grand_paris IS NOT NULL, 'Métropole du Grand Paris', compo.epci.nom) AS epci_nom,
    IF(compo.epci.siren IS NULL, NULL, compo.siren_metropole_grand_paris) AS siren_metropole_grand_paris,
    epci.type          AS epci_type,
    communes.dep_code,
    communes.dep_name,
    COALESCE(ml.siren, dep.siren) AS siren_departement,
    communes.reg_code,
    communes.reg_name,
    reg.siren          AS siren_region
FROM compo_une AS compo
LEFT JOIN communes USING (code_insee)
LEFT JOIN epci ON epci.siren = COALESCE(compo.epci.siren, compo.siren_metropole_grand_paris)
-- Bas-Rhin et Haut-Rhin : la Collectivité européenne d'Alsace depuis 2021 (code OFGL 67A).
LEFT JOIN dep  ON dep.code = IF(communes.dep_code IN ('67', '68'), '67A', communes.dep_code)
LEFT JOIN ml   ON ml.siren = compo.epci.siren
LEFT JOIN reg  ON reg.code = communes.reg_code
