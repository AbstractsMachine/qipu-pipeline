-- =============================================================================
-- Staging: Subventions versées (Annexe CA OpenData) + Annexe B8.1.1 PDF
--
-- Sources:
--   1. subventions_versees_annexe_compte_administratif_a_partir_de_2018
--      → Annexe CA via OpenData portal.
--      Complète pour 2018-2019 et 2022-2024.
--      Sur 2020 et 2021 : montants présents mais nom_de_l_organisme_beneficiaire
--      = NULL sur 100 % des lignes → inutilisable seul.
--   2. pdf_subventions_b811_paris  (raw, alimenté par sync_pdf_subventions_b811)
--      → Annexe B8.1.1 du CA en PDF, extraite localement.
--      Source exhaustive et nommée imposée par M57 (CGCT L. 2313-1).
--      Utilisée pour 2020 et 2021 (combler le trou OpenData), 2010-2012
--      (annexe M14 équivalente) et 2025+ (CA publié en PDF, pas encore
--      sur le portail).
--
-- Stratégie 2020 / 2021:
--   On exclut entièrement les lignes OpenData de ces deux années (toutes
--   anonymes) et on les remplace par les lignes PDF B8.1.1.
--   Les personnes physiques du PDF sont agrégées en une ligne par année
--   pour préserver le total sans exposer d'identité (RGPD : aides
--   individuelles, bourses, montants typiques 200-500 €).
--
-- Personnes physiques (toutes sources, tous exercices) :
--   Une ligne nature_juridique = « Personnes physiques » n'est jamais publiée
--   sous son nom : les particuliers sont agrégés en UNE ligne par exercice
--   (« Personnes physiques anonymisées RGPD (N aides individuelles) »), le
--   total de l'exercice reste juste au centime. Le jeu open data 2018+ nomme
--   ces particuliers (6 409 lignes en 2018, 8 392 en 2019…) : ils passaient
--   jusqu'ici tels quels (corrigé 2026-09-29).
--   Une ligne d'une autre nature privée (entreprise, « Autres »…) dont le nom
--   exact est étiqueté « Personnes physiques » par la Ville un autre exercice
--   (kiosquiers, taxis : « WEHBY » particulier en 2022, entreprise en 2023)
--   n'est pas nommée non plus : une ligne agrégée par exercice et nature
--   (bénéficiaires_non_nommes_homonymes) garde le total de la nature.
--   Garde-fou : pipeline/scripts/audit/check_personnes_physiques.py.
--
-- Transformations:
--   - Parse année depuis 'publication' ("CA 2023" → 2023) côté OpenData
--   - Normalisation nom bénéficiaire (pour jointures)
--   - Typage: FLOAT64 pour montants
--
-- Output: ~115k lignes, années 2010→2025.
-- =============================================================================

WITH source_opendata AS (
    SELECT *
    FROM {{ source('paris_raw', 'subventions_versees_annexe_compte_administratif_a_partir_de_2018') }}
),

opendata_all AS (
    SELECT
        -- =====================================================================
        -- IDENTIFIANTS
        -- =====================================================================

        -- Année extraite de "CA 2023" ou "2023" ou "2024"
        SAFE_CAST(
            REGEXP_EXTRACT(COALESCE(publication, ''), r'(\d{4})')
            AS INT64
        ) AS annee,

        -- Collectivité
        collectivite,

        -- =====================================================================
        -- BÉNÉFICIAIRE
        -- =====================================================================
        nom_de_l_organisme_beneficiaire AS beneficiaire,

        -- Bénéficiaire normalisé (pour jointures avec associations)
        -- Supprime articles, espaces multiples, met en majuscules
        UPPER(TRIM(REGEXP_REPLACE(
            REGEXP_REPLACE(
                REGEXP_REPLACE(
                    COALESCE(nom_de_l_organisme_beneficiaire, ''),
                    r"^(L'|LA |LE |LES |D'|DU |DE LA |DE L'|DES )", ''
                ),
                r'[^A-Za-zÀ-ÿ0-9\s]', ' '
            ),
            r'\s+', ' '
        ))) AS beneficiaire_normalise,

        -- Catégorie et nature juridique
        categorie_du_beneficiaire AS categorie,
        nature_juridique_du_beneficiaire AS nature_juridique,

        -- =====================================================================
        -- MONTANTS
        -- =====================================================================
        ABS(SAFE_CAST(montant_de_la_subvention AS FLOAT64)) AS montant,
        SAFE_CAST(prestations_en_nature AS FLOAT64) AS prestations_nature,

        -- =====================================================================
        -- FLAG QUALITÉ DONNÉES
        -- =====================================================================
        TRUE AS donnees_disponibles,

        -- =====================================================================
        -- SOURCE
        -- =====================================================================
        'opendata_annexe_ca' AS source_systeme,

        -- =====================================================================
        -- CLÉ TECHNIQUE - Base (sera complétée par row_number pour unicité)
        -- =====================================================================
        CONCAT(
            COALESCE(REGEXP_EXTRACT(publication, r'(\d{4})'), 'XXXX'), '-',
            COALESCE(collectivite, 'X'), '-',
            COALESCE(
                UPPER(TRIM(REGEXP_REPLACE(
                    COALESCE(nom_de_l_organisme_beneficiaire, 'INCONNU'),
                    r'\s+', ' '
                ))),
                'INCONNU'
            ), '-',
            COALESCE(SAFE_CAST(montant_de_la_subvention AS STRING), '0'), '-',
            -- Inclut catégorie + nature pour différencier lignes avec même montant
            SUBSTR(TO_HEX(MD5(CONCAT(
                COALESCE(categorie_du_beneficiaire, ''),
                COALESCE(nature_juridique_du_beneficiaire, '')
            ))), 1, 6)
        ) AS cle_technique

    FROM source_opendata
    WHERE
        -- Filtre montants positifs
        ABS(SAFE_CAST(montant_de_la_subvention AS FLOAT64)) > 0
        -- Filtre nom non NULL (sur 2020/2021 c'est 100 % des lignes ;
        -- on les ré-injecte depuis le PDF B8.1.1 ci-dessous)
        AND nom_de_l_organisme_beneficiaire IS NOT NULL
        -- Exclut 2020/2021 même si quelques noms existaient : on prend
        -- la source PDF (plus complète et cohérente) pour ces deux années
        AND SAFE_CAST(REGEXP_EXTRACT(COALESCE(publication, ''), r'(\d{4})') AS INT64)
            NOT IN (2020, 2021)
        -- 2025 et suivants : un exercice extrait de l'annexe B8.1.1 (PDF, totaux
        -- contrôlés au centime) n'est jamais pris deux fois. Si la Ville publie
        -- plus tard le même exercice sur le portail, la ligne PDF reste la
        -- référence tant qu'on ne retire pas l'extrait.
        AND SAFE_CAST(REGEXP_EXTRACT(COALESCE(publication, ''), r'(\d{4})') AS INT64)
            NOT IN (
                SELECT DISTINCT annee
                FROM {{ source('paris_raw_pdf', 'pdf_subventions_b811_paris') }}
                WHERE annee >= 2025
            )
),

-- Particuliers 2018+ (open data) : agrégation RGPD (1 ligne par exercice),
-- exactement comme les branches PDF et 2013-2017.
opendata_personnes_physiques AS (
    SELECT
        annee,
        'Paris' AS collectivite,
        CONCAT(
            'Personnes physiques anonymisées RGPD (',
            CAST(COUNT(*) AS STRING),
            ' aides individuelles)'
        ) AS beneficiaire,
        'PERSONNES PHYSIQUES ANONYMISEES RGPD' AS beneficiaire_normalise,
        'Personnes de droit privé' AS categorie,
        'Personnes physiques' AS nature_juridique,
        SUM(montant) AS montant,
        SUM(COALESCE(prestations_nature, 0)) AS prestations_nature,
        TRUE AS donnees_disponibles,
        'opendata_annexe_ca' AS source_systeme,
        CONCAT(CAST(annee AS STRING), '-Paris-PP-RGPD-AGGR-ODS18') AS cle_technique
    FROM opendata_all
    WHERE nature_juridique = 'Personnes physiques'
    GROUP BY annee
),

opendata_cleaned AS (
    SELECT * FROM opendata_all
    WHERE COALESCE(nature_juridique, '') != 'Personnes physiques'
),

-- ─── Source 2 : Annexe B8.1.1 PDF (2010-2012, 2020-2021, 2025+) ────────────
source_pdf_b811 AS (
    SELECT *
    FROM {{ source('paris_raw_pdf', 'pdf_subventions_b811_paris') }}
    -- 2020-2021 : annexe B8.1.1 (M57), trou de noms dans l'open data.
    -- 2010-2012 : annexe B1.6/B1.7 (M14), avant tout open data ; retrouvée
    -- dans l'archive du mini-site de la Ville, totaux contrôlés à l'euro.
    -- 2025 et suivants : annexe B8.1.1 du CA publiée en PDF avant (ou à la
    -- place) du jeu open data ; extraction refusée si un sous-total imprimé
    -- n'est pas retrouvé au centime (parse_subv_pdf_text.py --controle-totaux).
    WHERE annee IN (2010, 2011, 2012, 2020, 2021) OR annee >= 2025
),

-- Personnes physiques : agrégation RGPD (1 ligne par année)
pdf_personnes_physiques AS (
    SELECT
        annee,
        'Paris' AS collectivite,
        CONCAT(
            'Personnes physiques anonymisées RGPD (',
            CAST(COUNT(*) AS STRING),
            ' aides individuelles)'
        ) AS beneficiaire,
        'PERSONNES PHYSIQUES ANONYMISEES RGPD' AS beneficiaire_normalise,
        'Personnes de droit privé' AS categorie,
        'Personnes physiques' AS nature_juridique,
        SUM(montant_total) AS montant,
        SUM(COALESCE(prestations_nature, 0)) AS prestations_nature,
        TRUE AS donnees_disponibles,
        'pdf_b811' AS source_systeme,
        CONCAT(CAST(annee AS STRING), '-Paris-PP-RGPD-AGGR') AS cle_technique
    FROM source_pdf_b811
    WHERE nature_juridique = 'Personnes physiques'
    GROUP BY annee
),

-- Bénéficiaires nommés du PDF (tout sauf personnes physiques)
pdf_named AS (
    SELECT
        annee,
        'Paris' AS collectivite,
        name AS beneficiaire,
        -- 2020-2021 : clé produite par l'extracteur (sans accents, articles
        -- gardés), inchangée. 2025+ : même normalisation que les exercices
        -- open data (2013-2019, 2022-2024) et que stg_associations, pour que
        -- le bénéficiaire garde sa clé d'une année à l'autre et retrouve son
        -- dossier voté (objet, direction, SIRET). Mesuré sur 2025 : 2 991 noms
        -- retrouvent une clé 2022-2024 (contre 2 666), et 1 376 associations
        -- leur dossier voté (contre 1 105).
        CASE
            WHEN annee >= 2025 THEN UPPER(TRIM(REGEXP_REPLACE(
                REGEXP_REPLACE(
                    REGEXP_REPLACE(
                        COALESCE(name, ''),
                        r"^(L'|LA |LE |LES |D'|DU |DE LA |DE L'|DES )", ''
                    ),
                    r'[^A-Za-zÀ-ÿ0-9\s]', ' '
                ),
                r'\s+', ' '
            )))
            ELSE name_normalized
        END AS beneficiaire_normalise,
        COALESCE(categorie, '—') AS categorie,
        COALESCE(nature_juridique, '—') AS nature_juridique,
        montant_total AS montant,
        COALESCE(prestations_nature, 0) AS prestations_nature,
        TRUE AS donnees_disponibles,
        'pdf_b811' AS source_systeme,
        CONCAT(
            CAST(annee AS STRING), '-Paris-',
            UPPER(REGEXP_REPLACE(COALESCE(name, 'INCONNU'), r'\s+', ' ')), '-',
            CAST(CAST(montant_total AS INT64) AS STRING), '-',
            SUBSTR(TO_HEX(MD5(CONCAT(
                COALESCE(categorie, ''),
                COALESCE(nature_juridique, '')
            ))), 1, 6)
        ) AS cle_technique
    FROM source_pdf_b811
    WHERE COALESCE(nature_juridique, '') != 'Personnes physiques'
),

-- ─── Source 3 : Annexe CA OpenData 2013-2017 (M14-M52) ──────────────────────
--
-- La Ville a coupé la série au changement de plan comptable et republié la
-- suite sous un autre identifiant. On ne lisait que la seconde moitié : cinq
-- exercices et 6,19 Md€ n'existaient nulle part chez nous (constaté
-- 2026-09-10, total vérifié au million près contre l'agrégat du portail).
--
-- Différence de forme à connaître : ici les PARTICULIERS sont présents, sous
-- pseudonyme (« Nom 323 ») posé par la Ville, avec nature_juridique =
-- « Personnes physiques ». 21 218 lignes pour 11,4 M€, soit 0,2 % du total.
-- On les agrège en une ligne par exercice, exactement comme la branche PDF :
-- le total reste juste et aucune aide individuelle n'est exposée. Le jeu
-- 2018+ nomme ses particuliers en clair : même agrégation
-- (opendata_personnes_physiques).
source_ods_2013_2017 AS (
    SELECT
        SAFE_CAST(REGEXP_EXTRACT(COALESCE(publication, ''), r'(\d{4})') AS INT64) AS annee,
        nom_de_l_organisme_beneficiaire_d_une_subvention AS nom,
        COALESCE(categorie, '—') AS categorie,
        COALESCE(nature_juridique, '—') AS nature_juridique,
        ABS(SAFE_CAST(montant_de_la_subvention AS FLOAT64)) AS montant,
        COALESCE(ABS(SAFE_CAST(prestations_diverses AS FLOAT64)), 0) AS prestations_nature
    FROM {{ source('paris_raw', 'subventions_versees_2013_2017') }}
    WHERE ABS(SAFE_CAST(montant_de_la_subvention AS FLOAT64)) > 0
      AND SAFE_CAST(REGEXP_EXTRACT(COALESCE(publication, ''), r'(\d{4})') AS INT64) IS NOT NULL
),

-- ─── 2015 : les noms que l'open data a masqués ──────────────────────────────
-- Pour la publication « CA 2015 », la Ville a pseudonymisé (« Nom3950 ») 772
-- bénéficiaires qui ne sont PAS des particuliers : 133 établissements publics,
-- 61 entreprises, 533 associations… soit 668 M€. Les autres années, seuls les
-- particuliers le sont. L'annexe B1.7 du compte administratif 2015 les nomme :
-- seed_subventions_2015_noms_annexe ne garde que les rapprochements prouvés
-- (montant au centime ET code postal ; 116 lignes, 570,1 M€). Le montant de la
-- ligne doit encore correspondre ici, sinon on ne remplace rien.
-- Un pseudonyme non prouvé n'est jamais publié comme un nom : il rejoint une
-- ligne agrégée par nature juridique (ods_non_nommes).
-- Preuves : pipeline/raw_extracts/subventions_ca2015_annexe/.
noms_annexe_2015 AS (
    SELECT annee, pseudonyme, montant, nom_annexe
    FROM {{ ref('seed_subventions_2015_noms_annexe') }}
),

ods_2013_2017_resolu AS (
    SELECT
        s.*,
        COALESCE(n.nom_annexe, s.nom) AS nom_resolu,
        n.nom_annexe IS NOT NULL AS nom_depuis_annexe,
        (
            s.nature_juridique != 'Personnes physiques'
            AND REGEXP_CONTAINS(COALESCE(s.nom, ''), r'^Nom ?\d+$')
            AND n.nom_annexe IS NULL
        ) AS pseudonyme_non_resolu
    FROM source_ods_2013_2017 s
    LEFT JOIN noms_annexe_2015 n
        ON s.annee = n.annee
       AND s.nom = n.pseudonyme
       AND ABS(s.montant - n.montant) < 0.01
),

-- Pseudonymes non résolus : une ligne par exercice et nature juridique
ods_non_nommes AS (
    SELECT
        annee,
        'Paris' AS collectivite,
        CONCAT(
            'Bénéficiaires non nommés par la Ville — ', nature_juridique,
            ' (', CAST(COUNT(*) AS STRING), ' lignes)'
        ) AS beneficiaire,
        CONCAT('BENEFICIAIRES NON NOMMES PAR LA VILLE ', UPPER(nature_juridique)) AS beneficiaire_normalise,
        ANY_VALUE(categorie) AS categorie,
        nature_juridique,
        SUM(montant) AS montant,
        SUM(prestations_nature) AS prestations_nature,
        TRUE AS donnees_disponibles,
        'opendata_2013_2017' AS source_systeme,
        CONCAT(CAST(annee AS STRING), '-Paris-NON-NOMMES-',
               SUBSTR(TO_HEX(MD5(nature_juridique)), 1, 6)) AS cle_technique
    FROM ods_2013_2017_resolu
    WHERE pseudonyme_non_resolu
    GROUP BY annee, nature_juridique
),

-- Particuliers 2013-2017 : agrégation RGPD (1 ligne par exercice)
ods_2013_2017_personnes_physiques AS (
    SELECT
        annee,
        'Paris' AS collectivite,
        CONCAT(
            'Personnes physiques anonymisées RGPD (',
            CAST(COUNT(*) AS STRING),
            ' aides individuelles)'
        ) AS beneficiaire,
        'PERSONNES PHYSIQUES ANONYMISEES RGPD' AS beneficiaire_normalise,
        'Personnes de droit privé' AS categorie,
        'Personnes physiques' AS nature_juridique,
        SUM(montant) AS montant,
        SUM(prestations_nature) AS prestations_nature,
        TRUE AS donnees_disponibles,
        'opendata_2013_2017' AS source_systeme,
        CONCAT(CAST(annee AS STRING), '-Paris-PP-RGPD-AGGR-ODS') AS cle_technique
    FROM source_ods_2013_2017
    WHERE nature_juridique = 'Personnes physiques'
    GROUP BY annee
),

-- Bénéficiaires nommés 2013-2017 (tout sauf particuliers)
ods_2013_2017_named AS (
    SELECT
        annee,
        'Paris' AS collectivite,
        nom_resolu AS beneficiaire,
        UPPER(TRIM(REGEXP_REPLACE(
            REGEXP_REPLACE(
                REGEXP_REPLACE(
                    COALESCE(nom_resolu, ''),
                    r"^(L'|LA |LE |LES |D'|DU |DE LA |DE L'|DES )", ''
                ),
                r'[^A-Za-zÀ-ÿ0-9\s]', ' '
            ),
            r'\s+', ' '
        ))) AS beneficiaire_normalise,
        categorie,
        nature_juridique,
        montant,
        prestations_nature,
        TRUE AS donnees_disponibles,
        IF(nom_depuis_annexe, 'opendata_2013_2017+annexe_ca2015', 'opendata_2013_2017') AS source_systeme,
        CONCAT(
            CAST(annee AS STRING), '-Paris-',
            UPPER(REGEXP_REPLACE(COALESCE(nom_resolu, 'INCONNU'), r'\s+', ' ')), '-',
            CAST(CAST(montant AS INT64) AS STRING), '-',
            SUBSTR(TO_HEX(MD5(CONCAT(categorie, nature_juridique))), 1, 6)
        ) AS cle_technique
    FROM ods_2013_2017_resolu
    WHERE nature_juridique != 'Personnes physiques'
      AND nom IS NOT NULL
      AND NOT pseudonyme_non_resolu
),

-- ─── UNION des sources ───────────────────────────────────────────────────────
unioned_raw AS (
    SELECT * FROM opendata_cleaned
    UNION ALL
    SELECT * FROM opendata_personnes_physiques
    UNION ALL
    SELECT * FROM pdf_named
    UNION ALL
    SELECT * FROM pdf_personnes_physiques
    UNION ALL
    SELECT * FROM ods_2013_2017_named
    UNION ALL
    SELECT * FROM ods_2013_2017_personnes_physiques
    UNION ALL
    SELECT * FROM ods_non_nommes
),

-- ─── Homonymes de particuliers ──────────────────────────────────────────────
-- Noms que la Ville étiquette « Personnes physiques » au moins un exercice
-- (open data 2018+ et annexes PDF ; les pseudonymes « Nom 323 » de 2013-2017
-- n'en sont pas). Clé = nom exact, majuscules, espaces réduits : pas de
-- retrait d'article, pour que « LE BAL » ne tombe pas sur un particulier BAL.
noms_personnes_physiques AS (
    SELECT cle_nom
    FROM (
        SELECT UPPER(TRIM(REGEXP_REPLACE(nom_de_l_organisme_beneficiaire, r'\s+', ' '))) AS cle_nom
        FROM source_opendata
        WHERE nature_juridique_du_beneficiaire = 'Personnes physiques'
          AND nom_de_l_organisme_beneficiaire IS NOT NULL
        UNION DISTINCT
        SELECT UPPER(TRIM(REGEXP_REPLACE(name, r'\s+', ' ')))
        FROM source_pdf_b811
        WHERE nature_juridique = 'Personnes physiques'
          AND name IS NOT NULL
    )
    -- Libellés collectifs que la Ville range parfois sous « Personnes
    -- physiques » (remises gracieuses, copropriétés, dispositifs d'aide) :
    -- ce ne sont pas des noms de personne, ils restent publiés tels quels.
    WHERE NOT REGEXP_CONTAINS(cle_nom, r'REMISE|^REMG\b|^SDC\b|SUBVENTION|^AIDES?\b')
),

-- Lignes d'une autre nature privée portant l'un de ces noms. Les associations
-- et les personnes publiques restent nommées (personnes morales).
flagged AS (
    SELECT
        u.*,
        COALESCE(
            COALESCE(u.nature_juridique, '') != 'Personnes physiques'
            AND COALESCE(u.nature_juridique, '') NOT IN (
                'Associations', 'Etablissements publics', 'Établissements publics',
                'Etablissements de droit public', 'Autres personnes de droit public',
                'Etat', 'État', 'Communes', 'Département', 'Départements', 'Régions'
            )
            AND n.cle_nom IS NOT NULL,
            FALSE
        ) AS homonyme_particulier
    FROM unioned_raw u
    LEFT JOIN noms_personnes_physiques n
        ON UPPER(TRIM(REGEXP_REPLACE(u.beneficiaire, r'\s+', ' '))) = n.cle_nom
),

homonymes_agreges AS (
    SELECT
        annee,
        'Paris' AS collectivite,
        CONCAT(
            'Bénéficiaires non nommés — ', COALESCE(nature_juridique, '—'),
            ", même nom qu'un particulier (", CAST(COUNT(*) AS STRING),
            IF(COUNT(*) = 1, ' ligne)', ' lignes)')
        ) AS beneficiaire,
        CONCAT('BENEFICIAIRES NON NOMMES HOMONYMES PARTICULIERS ', UPPER(COALESCE(nature_juridique, '—'))) AS beneficiaire_normalise,
        MIN(categorie) AS categorie,
        nature_juridique,
        SUM(montant) AS montant,
        SUM(COALESCE(prestations_nature, 0)) AS prestations_nature,
        TRUE AS donnees_disponibles,
        MIN(source_systeme) AS source_systeme,
        CONCAT(CAST(annee AS STRING), '-Paris-HOMONYMES-PP-',
               SUBSTR(TO_HEX(MD5(COALESCE(nature_juridique, '—'))), 1, 6)) AS cle_technique
    FROM flagged
    WHERE homonyme_particulier
    GROUP BY annee, nature_juridique
),

unioned AS (
    SELECT * EXCEPT (homonyme_particulier) FROM flagged WHERE NOT homonyme_particulier
    UNION ALL
    SELECT * FROM homonymes_agreges
),

-- Ajoute un suffixe numérique pour les rares doublons restants
with_unique_key AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY cle_technique ORDER BY beneficiaire) as rn
    FROM unioned
)

SELECT
    annee,
    collectivite,
    beneficiaire,
    beneficiaire_normalise,
    categorie,
    nature_juridique,
    montant,
    prestations_nature,
    donnees_disponibles,
    source_systeme,
    CASE
        WHEN rn > 1 THEN CONCAT(cle_technique, '-', CAST(rn AS STRING))
        ELSE cle_technique
    END AS cle_technique
FROM with_unique_key
