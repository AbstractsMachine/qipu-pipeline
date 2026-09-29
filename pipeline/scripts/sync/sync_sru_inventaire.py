#!/usr/bin/env python3
"""
Inventaire SRU, taux de logements sociaux de chaque commune soumise à la loi
SRU → raw_national.sru_inventaire (2026-09-23).

La page Logement de Paris ouvrait sur un taux tapé à la main dans
seed_city_constants.csv (24,5 %, 258 400 logements, « DDT de Paris,
inventaire 2024 ») que rien ne mettait à jour. Le ministère de la Transition
écologique publie chaque année sur data.gouv.fr « Communes et inventaire SRU » :
une ligne par commune soumise à la loi (≈ 2 200), avec le nombre de logements
sociaux décomptés et le taux au 1er janvier. Pour Paris au 1er janvier 2025 :
276 032 logements, 23,21 %.

Un fichier par millésime, et la forme change d'un millésime à l'autre
(séparateur « ; » ou « , », une ligne vide avant l'en-tête, l'année dans le nom
des colonnes : « Taux_SRU_au_01_01_2025 »). Les colonnes sont donc trouvées par
leur nom, l'année de l'inventaire lue dans ce nom. Un fichier dont on ne trouve
pas les colonnes, ou sans ligne pour Paris, arrête le chargement : la table
reste telle quelle.

Version = la date de modification de chaque CSV du jeu : un millésime nouveau,
ou un fichier republié (le 2025 l'a été en « v2 »), et tous sont relus.
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import re
import sys
import unicodedata
from pathlib import Path
from urllib.request import Request, urlopen

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import _national_raw as NR  # noqa: E402

TABLE = "sru_inventaire"
DATASET_API = "https://www.data.gouv.fr/api/1/datasets/6564969d3579e21795ebd378/"
COLUMNS = ["annee_inventaire", "code_insee", "nom", "population", "nb_lls", "taux_sru", "taux_cible",
           "deficitaire", "carencee", "exemptee", "fichier", "source_url"]
BQ_SCHEMA = ("annee_inventaire:INTEGER,code_insee:STRING,nom:STRING,population:INTEGER,nb_lls:INTEGER,"
             "taux_sru:FLOAT,taux_cible:FLOAT,deficitaire:BOOLEAN,carencee:BOOLEAN,exemptee:BOOLEAN,"
             "fichier:STRING,source_url:STRING")
UA = {"User-Agent": "Mozilla/5.0 (qipu-pipeline)"}
CACHE_DIR = HERE.parents[1] / "cache" / "wip" / "national" / "sru"
MIN_COMMUNES = 1000


def get(url: str) -> bytes:
    with urlopen(Request(url, headers=UA), timeout=120) as r:
        return r.read()


def catalogue() -> tuple[str, list[dict]]:
    """The dataset page and its per-year CSV files, newest first."""
    d = json.loads(get(DATASET_API))
    files = [r for r in d["resources"] if (r.get("format") or "").lower() == "csv" and r["title"].lower().startswith("donnees-sru")]
    if not files:
        raise SystemExit("✗ aucun CSV « donnees-sru » dans le jeu data.gouv — le jeu a-t-il changé ?")
    files.sort(key=lambda r: r.get("last_modified") or "", reverse=True)
    return d.get("page") or "https://www.data.gouv.fr/datasets/communes-et-inventaire-sru/", files


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_")


def pct(v: str) -> float | None:
    v = (v or "").replace(" ", " ").replace("%", "").replace(" ", "").replace(",", ".").strip()
    try:
        return float(v)
    except ValueError:
        return None


def entier(v: str) -> int | None:
    v = re.sub(r"[^\d-]", "", v or "")
    try:
        return int(v)
    except ValueError:
        return None


def oui(v: str) -> bool | None:
    v = (v or "").strip()
    return None if v == "" else v == "1"


def lire(raw: bytes, fichier: str) -> tuple[int, list[dict]]:
    """(inventory year, rows) of one yearly file."""
    for enc in ("utf-8-sig", "cp1252"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    sample = text[:20000]
    delim = ";" if sample.count(";") > sample.count(",") else ","
    rows = list(csv.reader(io.StringIO(text), delimiter=delim))
    at = next((i for i, r in enumerate(rows[:10]) if any(norm(c) == "code_insee_commune" for c in r)), None)
    if at is None:
        raise SystemExit(f"✗ {fichier} : pas de colonne Code_INSEE_commune dans les 10 premières lignes")
    head = [norm(c) for c in rows[at]]

    def col(prefix: str, required: bool = True) -> int | None:
        i = next((j for j, c in enumerate(head) if c.startswith(prefix)), None)
        if i is None and required:
            raise SystemExit(f"✗ {fichier} : colonne « {prefix}… » introuvable ({', '.join(head)})")
        return i

    c_insee, c_nom, c_pop = col("code_insee_commune"), col("nom_commune"), col("population_municipale", False)
    c_lls, c_taux = col("nombre_lls"), col("taux_sru_au_01_01_")
    c_cible, c_def = col("taux_cible"), col("commune_deficitaire", False)
    c_car, c_exe = col("commune_carencee", False), col("commune_exemptee", False)
    annee = int(re.search(r"(\d{4})$", head[c_taux]).group(1))
    lls_annee = re.search(r"(\d{4})$", head[c_lls])
    if lls_annee and int(lls_annee.group(1)) != annee:
        raise SystemExit(f"✗ {fichier} : logements au {lls_annee.group(1)}, taux au {annee} — colonnes incohérentes")

    out = []
    for r in rows[at + 1:]:
        if len(r) <= max(c_insee, c_taux) or not r[c_insee].strip():
            continue
        insee = r[c_insee].strip().zfill(5)
        at_ = lambda i: r[i] if i is not None and i < len(r) else ""  # noqa: E731
        out.append({
            "annee_inventaire": annee,
            "code_insee": insee,
            "nom": r[c_nom].strip(),
            "population": entier(at_(c_pop)),
            "nb_lls": entier(r[c_lls]),
            "taux_sru": pct(r[c_taux]),
            "taux_cible": pct(r[c_cible]),
            "deficitaire": oui(at_(c_def)),
            "carencee": oui(at_(c_car)),
            "exemptee": oui(at_(c_exe)),
        })
    if len(out) < MIN_COMMUNES:
        raise SystemExit(f"✗ {fichier} : {len(out)} communes seulement — table inchangée")
    paris = [x for x in out if x["code_insee"] == "75056"]
    if not paris or paris[0]["taux_sru"] is None or not paris[0]["nb_lls"]:
        raise SystemExit(f"✗ {fichier} : pas de taux ni de logements pour Paris (75056) — table inchangée")
    return annee, out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    page, files = catalogue()
    version = {r["id"]: r.get("last_modified") or "" for r in files}
    if NR.is_version_current(TABLE, version) and not args.force:
        print(f"  = {TABLE} : {len(files)} fichiers déjà chargés — rien à faire")
        return 0
    old = NR.meta(TABLE).get("version") or {}
    changed = [r["title"] for r in files if old.get(r["id"]) != version[r["id"]]]
    print(f"→ inventaire SRU → {NR.DATASET_ID}.{TABLE} — nouveau ou modifié : {', '.join(changed)}")
    if NR.CHECK_ONLY:
        NR.would_change(TABLE, ", ".join(changed))
        return 0

    # One inventory year per file; a year published twice keeps the newest file.
    par_annee: dict[int, list[dict]] = {}
    for r in files:
        annee, rows = lire(get(r["url"]), r["title"])
        if annee in par_annee:
            print(f"  {r['title']} : inventaire {annee} déjà lu dans un fichier plus récent, ignoré")
            continue
        for x in rows:
            x["fichier"], x["source_url"] = r["url"], page
        par_annee[annee] = rows
        p = next(x for x in rows if x["code_insee"] == "75056")
        print(f"  {r['title']} : inventaire au 1er janvier {annee}, {len(rows)} communes — Paris {p['nb_lls']:,} logements, {p['taux_sru']} %")
    if args.dry_run:
        return 0

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    out = CACHE_DIR / "sru_inventaire.csv"
    n = 0
    with open(out, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        w.writeheader()
        for annee in sorted(par_annee):
            for x in par_annee[annee]:
                w.writerow({c: ("" if x.get(c) is None else x[c]) for c in COLUMNS})
                n += 1
    NR.replace_snapshot(TABLE, out, BQ_SCHEMA, version=version,
                        load_args=("--source_format=CSV", "--skip_leading_rows=1"), force=args.force)
    print(f"✓ {n} lignes, inventaires {', '.join(map(str, sorted(par_annee)))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
