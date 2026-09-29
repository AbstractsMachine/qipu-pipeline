#!/usr/bin/env python3
"""
DGFiP « balances comptables … présentation croisée nature-fonction » → BigQuery
`raw_national.dgfip_balances_nature_fonction`. Chargement brut, rien d'autre.

Ce que la source est :
    Un ZIP par exercice, publié en pièce jointe d'un jeu data.economie.gouv.fr
    dont l'identifiant porte l'année (…-nature-fonction-2024, …-2025). Dedans,
    un CSV `;` en ISO-8859-1, décimales à virgule, 30 colonnes. Chaque ligne
    porte À LA FOIS une FONCTION (la politique publique) et un COMPTE (la
    nature), pour TOUTES les collectivités : communes, Paris, groupements à
    fiscalité propre, départements, régions, syndicats, EPL…

Ce que ce script fait :
    Il copie ces lignes telles quelles dans BigQuery — toutes les catégories,
    toutes les colonnes, en texte (« 96971,23 » reste « 96971,23 ») — avec
    trois colonnes de chargement :
      annee           l'exercice (contrôlé contre EXER, ligne à ligne)
      ligne           le rang de la ligne dans le CSV (1 = première ligne de
                      données) : l'ordre de la source, que l'export rejoue
      source_fichier  le nom du CSV chargé (il date la republication)
    Le typage, les codes INSEE, les clés de fonction, le périmètre des
    communes : tout ça vit dans dbt (stg_dgfip_nature_fonction →
    core_dgfip_nature_fonction → mart_communes_fonctions), pas ici.

Rafraîchissement automatique (mode par défaut, sans argument) :
    1. les exercices publiés se lisent dans le catalogue (un jeu par année) ;
    2. pour chacun, le nombre de lignes annoncé par l'API du jeu est comparé au
       nombre de lignes déjà chargées pour cet `annee` ;
    3. seuls se chargent les exercices absents, ou dont le compte diffère.
    Chaque exercice chargé imprime UNE ligne :
        NATIONAL CHANGED dgfip_balances_nature_fonction (<annee> : <avant> → <après> lignes)
    et, si la variable d'environnement NATIONAL_CHANGES_FILE est définie, y
    ajoute la ligne `dgfip_balances_nature_fonction`.
    Rien de neuf → « = rien à charger », code 0, aucune écriture.

Garde : un exercice n'est jamais remplacé par moins de 90 % de ses lignes
actuelles (une republication tronquée ne doit pas effacer ce qu'on a), sauf
--force. Une garde déclenchée saute cet exercice, laisse les autres se charger,
et fait sortir le script en code 1.

Idempotent : la table est partitionnée par `annee` ; charger un exercice
remplace sa partition et ne touche pas aux autres. Le ZIP est gardé en cache
(pipeline/cache/dgfip/). Le CSV converti doit compter exactement les lignes
annoncées par l'API : sinon le ZIP est re-téléchargé une fois, puis l'exercice
est abandonné.

Usage :
    python3 pipeline/scripts/sync/sync_dgfip_nature_fonction.py                 # tous les exercices publiés, si changés
    python3 pipeline/scripts/sync/sync_dgfip_nature_fonction.py --dry-run       # ce qui serait chargé, sans rien écrire
    python3 pipeline/scripts/sync/sync_dgfip_nature_fonction.py --annee 2025    # un seul exercice, si changé
    python3 pipeline/scripts/sync/sync_dgfip_nature_fonction.py --derniere      # le dernier exercice publié, si changé
    python3 pipeline/scripts/sync/sync_dgfip_nature_fonction.py --annee 2024 --force   # recharger quand même
    python3 pipeline/scripts/sync/sync_dgfip_nature_fonction.py --lister        # exercices publiés

Codes de sortie : 0 = à jour ou chargé ; 1 = garde déclenchée ou exercice en
échec ; 2 = invocation invalide.

Chaîne complète (fonctions.json par commune) :
    1. ce script
    2. cd pipeline && dbt run  --target prod --select stg_dgfip_nature_fonction core_dgfip_nature_fonction mart_communes_fonctions
       cd pipeline && dbt test --target prod --select stg_dgfip_nature_fonction core_dgfip_nature_fonction mart_communes_fonctions
    3. python3 pipeline/scripts/export/export_communes_fonctions.py   (exercice le plus récent du mart)
    4. gcloud storage rsync -r website/public/data/communes-fonctions gs://qipu-communes-budget/communes-fonctions

Source :
    https://data.economie.gouv.fr/explore/dataset/balances-comptables-des-
    collectivites-et-des-etablissements-publics-locaux-avec-la-presentation-
    croisee-nature-fonction-2024/   (et -2025, …)
"""

from __future__ import annotations

import argparse
import csv
import gzip
import io
import json
import os
import re
import sys
import zipfile
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[3]
CACHE_DIR = ROOT / "pipeline" / "cache" / "dgfip"

PROJECT_ID = "open-data-france-484717"
DATASET_ID = "raw_national"
TABLE = "dgfip_balances_nature_fonction"
TABLE_PAR_DEFAUT = f"{PROJECT_ID}.{DATASET_ID}.{TABLE}"

CATALOG = "https://data.economie.gouv.fr/api/explore/v2.1/catalog"
DATASET_PREFIX = (
    "balances-comptables-des-collectivites-et-des-etablissements-publics-"
    "locaux-avec-la-presentation-croisee-nature-fonction-"
)
SEUIL_GARDE = 0.90

# L'en-tête exact du CSV. Une colonne ajoutée, retirée ou déplacée par la DGFiP
# arrête le chargement : on ne devine pas ce qu'est devenue une colonne.
COLONNES = [
    "EXER", "IDENT", "NDEPT", "LBUDG", "MODVTHEL", "INSEE", "CBUDG", "CTYPE",
    "CSTYP", "NOMEN", "siren", "CREGI", "CACTI", "SECTEUR", "FINESS", "CODBUD1",
    "CATEG", "BAL", "FONCTION", "COMPTE", "BEDEB", "BECRE", "OBNETDEB",
    "OBNETCRE", "ONBDEB", "ONBCRE", "OOBDEB", "OOBCRE", "SD", "SC",
]
# Tout en texte : les codes gardent leurs zéros de tête (NDEPT « 075 », compte
# « 60611 »), les montants leur écriture d'origine. dbt type.
SCHEMA = (
    [("annee", "INTEGER", "REQUIRED"), ("ligne", "INTEGER", "REQUIRED")]
    + [(c.lower(), "STRING", "NULLABLE") for c in COLONNES]
    + [("source_fichier", "STRING", "REQUIRED")]
)
PARTITION_RANGE = (2010, 2051, 1)


def _log(msg: str) -> None:
    print(msg, flush=True)


def _get_json(url: str) -> dict:
    req = Request(url, headers={"User-Agent": "qipu-pipeline/1.0"})
    with urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode("utf-8"))


# ---------------------------------------------------------------------------
# Catalogue

def dataset_id(annee: int) -> str:
    return f"{DATASET_PREFIX}{annee}"


def annees_publiees() -> list[int]:
    """Les exercices publiés, lus dans le catalogue : un jeu par année."""
    annees: list[int] = []
    offset = 0
    while True:
        q = urlencode({
            "where": f'startswith(dataset_id, "{DATASET_PREFIX}")',
            "select": "dataset_id",
            "limit": 100,
            "offset": offset,
        })
        page = _get_json(f"{CATALOG}/datasets?{q}")
        results = page.get("results", [])
        for r in results:
            m = re.fullmatch(re.escape(DATASET_PREFIX) + r"(\d{4})", r["dataset_id"])
            if m:
                annees.append(int(m.group(1)))
        offset += len(results)
        if not results or offset >= page.get("total_count", 0):
            break
    return sorted(set(annees))


def piece_jointe_zip(annee: int) -> tuple[str, str]:
    """(url, nom de fichier) du ZIP de l'exercice.

    L'identifiant de la pièce jointe change d'une publication à l'autre
    (« balancespl_fonction_2024_dec2025_zip », « balancespl_fonction_2025_juil2026zip ») :
    on le cherche, on ne le reconstruit pas.
    """
    data = _get_json(f"{CATALOG}/datasets/{dataset_id(annee)}/attachments")
    zips = [a["metas"] for a in data.get("attachments", [])
            if a.get("metas", {}).get("mimetype") == "application/zip"]
    balances = [m for m in zips if m["id"].startswith(f"balancespl_fonction_{annee}")]
    choix = balances or zips
    if len(choix) != 1:
        raise RuntimeError(f"{annee} : {len(choix)} ZIP candidats dans les pièces jointes — {[m['id'] for m in zips]}")
    return choix[0]["url"], choix[0]["title"]


def nombre_attendu(annee: int) -> int:
    return int(_get_json(f"{CATALOG}/datasets/{dataset_id(annee)}/records?limit=0")["total_count"])


# ---------------------------------------------------------------------------
# Décision : quoi charger

def planifier(publies: dict[int, int], charges: dict[int, int], force: bool) -> tuple[list[int], list[int], list[int]]:
    """(à charger, à jour, bloqués par la garde), à partir des comptes.

    publies : annee → lignes annoncées par l'API ; charges : annee → lignes en table.
    """
    a_charger, a_jour, bloques = [], [], []
    for annee in sorted(publies):
        nouveau, actuel = publies[annee], charges.get(annee, 0)
        if nouveau == actuel and not force:
            a_jour.append(annee)
        elif actuel > 0 and nouveau < SEUIL_GARDE * actuel and not force:
            bloques.append(annee)
        else:
            a_charger.append(annee)
    return a_charger, a_jour, bloques


# ---------------------------------------------------------------------------
# Téléchargement et conversion

def telecharger(url: str, nom: str, force: bool) -> tuple[Path, bool]:
    """(chemin du ZIP, vient d'être téléchargé ?)."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cible = CACHE_DIR / nom
    if cible.exists() and not force:
        _log(f"  = ZIP en cache : {cible.name} ({cible.stat().st_size / 1e6:.0f} Mo)")
        return cible, False
    _log(f"  ↓ {url}")
    partiel = cible.with_suffix(cible.suffix + ".part")
    req = Request(url, headers={"User-Agent": "qipu-pipeline/1.0"})
    with urlopen(req, timeout=600) as resp, open(partiel, "wb") as f:
        while chunk := resp.read(1 << 20):
            f.write(chunk)
    partiel.replace(cible)
    _log(f"  ✓ {cible.name} ({cible.stat().st_size / 1e6:.0f} Mo)")
    return cible, True


def convertir(zip_path: Path, annee: int) -> tuple[Path, int]:
    """ZIP → CSV UTF-8 gzippé prêt pour BigQuery. Renvoie (chemin, lignes)."""
    with zipfile.ZipFile(zip_path) as zf:
        csvs = [n for n in zf.namelist() if n.lower().endswith(".csv")]
        if len(csvs) != 1:
            raise RuntimeError(f"{zip_path.name} : {len(csvs)} CSV dans le ZIP — {csvs}")
        nom_csv = csvs[0]
        dest = CACHE_DIR / f"{Path(nom_csv).stem}.bq.csv.gz"
        n = 0
        with zf.open(nom_csv) as raw, gzip.open(dest, "wt", encoding="utf-8", newline="") as out:
            texte = io.TextIOWrapper(raw, encoding="iso-8859-1", newline="")
            reader = csv.reader(texte, delimiter=";")
            entete = next(reader, None)
            if entete != COLONNES:
                raise RuntimeError(f"en-tête inattendu dans {nom_csv} :\n  reçu    {entete}\n  attendu {COLONNES}")
            writer = csv.writer(out, lineterminator="\n")
            writer.writerow([c for c, _, _ in SCHEMA])
            for row in reader:
                n += 1
                if len(row) != len(COLONNES):
                    raise RuntimeError(f"{nom_csv} ligne {n} : {len(row)} colonnes au lieu de {len(COLONNES)}")
                if row[0] != str(annee):
                    raise RuntimeError(f"{nom_csv} ligne {n} : EXER={row[0]!r}, exercice attendu {annee}")
                writer.writerow([annee, n, *row, nom_csv])
    _log(f"  ✓ {n:,} lignes converties → {dest.name} ({dest.stat().st_size / 1e6:.0f} Mo)")
    return dest, n


# ---------------------------------------------------------------------------
# BigQuery

def client_bq():
    from google.cloud import bigquery

    if not os.environ.get("GOOGLE_APPLICATION_CREDENTIALS"):
        adc = Path.home() / ".config" / "gcloud" / "application_default_credentials.json"
        if adc.exists():
            os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = str(adc)
    return bigquery.Client(project=PROJECT_ID)


def lignes_chargees(client, table: str) -> dict[int, int]:
    """annee → nombre de lignes déjà en table ({} si la table n'existe pas)."""
    from google.api_core.exceptions import NotFound

    try:
        client.get_table(table)
    except NotFound:
        return {}
    rows = client.query(f"SELECT annee, COUNT(*) AS n FROM `{table}` GROUP BY annee").result()
    return {r["annee"]: r["n"] for r in rows}


def assurer_table(client, table: str) -> None:
    from google.api_core.exceptions import NotFound
    from google.cloud import bigquery

    try:
        client.get_table(table)
        return
    except NotFound:
        pass
    t = bigquery.Table(table, schema=[bigquery.SchemaField(n, ty, mode=m) for n, ty, m in SCHEMA])
    start, end, interval = PARTITION_RANGE
    t.range_partitioning = bigquery.RangePartitioning(
        field="annee", range_=bigquery.PartitionRange(start=start, end=end, interval=interval)
    )
    t.clustering_fields = ["categ", "cbudg"]
    t.description = (
        "DGFiP — balances comptables des collectivités et EPL, présentation croisée "
        "nature-fonction. Copie fidèle du CSV (toutes catégories, toutes colonnes, en texte), "
        "un exercice par partition. Chargé par pipeline/scripts/sync/sync_dgfip_nature_fonction.py."
    )
    client.create_table(t)
    _log(f"  + table créée : {table} (partition annee, cluster categ, cbudg)")


def charger(client, table: str, gz_path: Path, annee: int, attendu: int) -> None:
    from google.cloud import bigquery

    assurer_table(client, table)
    config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.CSV,
        skip_leading_rows=1,
        schema=[bigquery.SchemaField(n, t, mode=m) for n, t, m in SCHEMA],
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )
    _log(f"  → chargement de la partition {annee} (remplacée) …")
    with open(gz_path, "rb") as f:
        job = client.load_table_from_file(f, f"{table}${annee}", job_config=config)
    job.result()
    if job.output_rows != attendu:
        raise RuntimeError(f"{annee} : {job.output_rows:,} lignes chargées, {attendu:,} attendues")


def signaler_changement(annee: int, avant: int, apres: int) -> None:
    """Le protocole du rafraîchissement national : une ligne, et le fichier des changements."""
    print(f"NATIONAL CHANGED {TABLE} ({annee} : {avant} → {apres} lignes)", flush=True)
    chemin = os.environ.get("NATIONAL_CHANGES_FILE")
    if chemin:
        with open(chemin, "a", encoding="utf-8") as f:
            f.write(f"{TABLE}\n")


def charger_exercice(client, table: str, annee: int, attendu: int, avant: int, force: bool) -> None:
    url, nom_zip = piece_jointe_zip(annee)
    zip_path, frais = telecharger(url, nom_zip, force)
    gz_path, n = convertir(zip_path, annee)
    if n != attendu and not frais:
        # Même nom de fichier, contenu republié : le cache est périmé.
        _log(f"  ! {n:,} lignes dans le ZIP en cache, {attendu:,} annoncées — nouveau téléchargement")
        zip_path, _ = telecharger(url, nom_zip, True)
        gz_path, n = convertir(zip_path, annee)
    if n != attendu:
        raise RuntimeError(f"{annee} : {n:,} lignes dans le CSV, {attendu:,} annoncées par l'API — non chargé")
    charger(client, table, gz_path, annee, n)
    signaler_changement(annee, avant, n)


# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--annee", type=int, help="ne considérer que cet exercice")
    ap.add_argument("--derniere", action="store_true", help="ne considérer que le dernier exercice publié")
    ap.add_argument("--lister", action="store_true", help="afficher les exercices publiés et s'arrêter")
    ap.add_argument("--force", action="store_true",
                    help="recharger même à compte égal, passer outre la garde des 90 %%, re-télécharger le ZIP")
    ap.add_argument("--dry-run", action="store_true", help="dire ce qui serait chargé, sans rien télécharger ni écrire")
    ap.add_argument("--table", default=TABLE_PAR_DEFAUT, help=f"table cible (défaut {TABLE_PAR_DEFAUT} ; autre = essais)")
    args = ap.parse_args()
    if args.annee is not None and args.derniere:
        ap.error("--annee et --derniere s'excluent")

    annees = annees_publiees()
    _log(f"→ Balance DGFiP nature-fonction → {args.table}")
    _log(f"  = exercices publiés au catalogue : {', '.join(map(str, annees)) or 'aucun'}")
    if args.lister:
        return 0
    if not annees:
        _log("✗ aucun exercice trouvé au catalogue")
        return 1
    if args.annee is not None:
        if args.annee not in annees:
            _log(f"✗ l'exercice {args.annee} n'est pas publié ({dataset_id(args.annee)} absent du catalogue)")
            return 1
        annees = [args.annee]
    elif args.derniere:
        annees = annees[-1:]

    publies = {a: nombre_attendu(a) for a in annees}
    client = client_bq()
    charges = lignes_chargees(client, args.table)
    a_charger, a_jour, bloques = planifier(publies, charges, args.force)

    for a in a_jour:
        _log(f"  = {a} : à jour ({charges.get(a, 0):,} lignes)")
    for a in bloques:
        _log(f"  ✗ GARDE {a} : l'API annonce {publies[a]:,} lignes contre {charges[a]:,} en table "
             f"(< {SEUIL_GARDE:.0%}) — non rechargé ; --force pour passer outre")
    for a in a_charger:
        _log(f"  → {a} : {'serait chargé' if args.dry_run else 'à charger'} "
             f"({charges.get(a, 0):,} → {publies[a]:,} lignes)")

    # La veille du mardi (NATIONAL_CHECK_ONLY=1, voir _national_raw) : dire ce
    # qui serait rechargé, au même fichier que les vrais changements, et
    # s'arrêter avant tout téléchargement.
    veille = os.environ.get("NATIONAL_CHECK_ONLY") == "1"
    if veille:
        for a in a_charger:
            print(f"NATIONAL WOULD CHANGE {TABLE} ({a} : {charges.get(a, 0)} → {publies[a]} lignes)", flush=True)
            chemin = os.environ.get("NATIONAL_CHANGES_FILE")
            if chemin:
                with open(chemin, "a", encoding="utf-8") as f:
                    f.write(f"{TABLE}\n")
    if args.dry_run or veille:
        _log("  (dry-run — rien n'est téléchargé ni écrit)")
        return 1 if bloques else 0
    if not a_charger:
        _log("  = rien à charger")
        return 1 if bloques else 0

    echecs = []
    for a in a_charger:
        _log(f"→ exercice {a}")
        try:
            charger_exercice(client, args.table, a, publies[a], charges.get(a, 0), args.force)
        except Exception as e:  # un exercice en échec n'empêche pas les autres
            _log(f"  ✗ {a} : {e}")
            echecs.append(a)
    return 1 if (bloques or echecs) else 0


if __name__ == "__main__":
    sys.exit(main())
