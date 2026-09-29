#!/usr/bin/env python3
"""
National ingest — Répertoire national des élus (conseillers municipaux)
→ raw_national.rne_conseillers_municipaux (BigQuery).

Source : ministère de l'Intérieur, data.gouv.fr, licence ouverte, à jour du
renouvellement de mars 2026.

Vie privée (règle du site, 2026-09-09) : on ne garde QUE ce qui sert à dire
« Maire : Prénom Nom, depuis mars 2026 · 49 conseillers » — commune, nom,
prénom, fonction, dates de mandat et de fonction. La date de naissance, la
catégorie socioprofessionnelle, la nationalité et le sexe ne sont jamais
chargés, même en privé.

Mise à jour automatique (2026-09-14) : le répertoire est un état courant, la
table est donc remplacée en entier, mais seulement quand data.gouv.fr publie une
nouvelle version (URL et date rangées dans la description), et jamais par un
fichier qui compterait moins de 90 % des élus actuels (_national_raw).

Usage :
    python scripts/sync/sync_rne_maires.py              # charge si nouvelle version
    python scripts/sync/sync_rne_maires.py --dry-run    # dit s'il y a une nouvelle version
    python scripts/sync/sync_rne_maires.py --force
"""
from __future__ import annotations

import csv
import io
import json
import subprocess
import sys
import urllib.request
import argparse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _national_raw as NR  # noqa: E402

PROJECT_ID = "open-data-france-484717"
DATASET_ID = "raw_national"
TABLE = "rne_conseillers_municipaux"
DATASET_API = "https://www.data.gouv.fr/api/1/datasets/repertoire-national-des-elus-1/"

KEEP = {
    "Code du département": "dep_code",
    "Libellé du département": "dep_name",
    "Code de la commune": "com_code",
    "Libellé de la commune": "com_name",
    "Nom de l'élu": "nom",
    "Prénom de l'élu": "prenom",
    "Date de début du mandat": "date_debut_mandat",
    "Libellé de la fonction": "fonction",
    "Date de début de la fonction": "date_debut_fonction",
}
BQ_SCHEMA = "dep_code:STRING,dep_name:STRING,com_code:STRING,com_name:STRING,nom:STRING,prenom:STRING,date_debut_mandat:STRING,fonction:STRING,date_debut_fonction:STRING"

ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = ROOT / "cache" / "wip" / "national" / "rne"


def current_resource() -> dict:
    with urllib.request.urlopen(DATASET_API, timeout=60) as r:
        d = json.load(r)
    for res in d["resources"]:
        if "conseillers-municipaux" in (res.get("title") or "").lower() or "conseiller-municipal" in (res.get("url") or ""):
            return {"url": res["url"], "last_modified": res.get("last_modified")}
    raise SystemExit("fichier des conseillers municipaux introuvable")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    res = current_resource()
    if NR.is_version_current(TABLE, res) and not args.force:
        print(f"  = {TABLE} : version {res['last_modified']} déjà chargée — rien à faire")
        return 0
    print(f"→ RNE → {NR.DATASET_ID}.{TABLE} — nouvelle version {res['last_modified']}")
    if args.dry_run or NR.CHECK_ONLY:
        if NR.CHECK_ONLY:
            NR.would_change(TABLE, f"version {res['last_modified']}")
        return 0
    print(f"  téléchargement {res['url']}")
    raw = urllib.request.urlopen(res["url"], timeout=600).read().decode("utf-8", errors="replace")
    reader = csv.DictReader(io.StringIO(raw), delimiter=";")
    missing = [k for k in KEEP if k not in (reader.fieldnames or [])]
    if missing:
        raise SystemExit(f"colonnes attendues absentes : {missing}")
    out = CACHE_DIR / "rne_conseillers_municipaux.csv"
    n = 0
    with open(out, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(list(KEEP.values()))
        for row in reader:
            w.writerow([(row.get(k) or "").strip() for k in KEEP])
            n += 1
    print(f"  {n:,} élus, {len(KEEP)} colonnes (aucune donnée sensible) → {out.name}")
    NR.replace_snapshot(TABLE, out, BQ_SCHEMA, version=res,
                        load_args=("--source_format=CSV", "--skip_leading_rows=1", "--allow_quoted_newlines"), force=args.force)
    return 0


if __name__ == "__main__":
    sys.exit(main())
