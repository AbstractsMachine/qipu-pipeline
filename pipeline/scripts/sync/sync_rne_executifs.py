#!/usr/bin/env python3
"""
Répertoire national des élus — conseils départementaux, régionaux et
communautaires → raw_national.rne_executifs (BigQuery).

Pourquoi (2026-09-26, échelle des niveaux) : la page d'une région, d'un
département ou d'une intercommunalité dit qui la préside et combien d'élus
siègent à son conseil, comme la page d'une commune dit son maire.

Source : ministère de l'Intérieur, data.gouv.fr « Répertoire national des
élus », licence ouverte, trois fichiers (mis à jour chaque trimestre) :
  elus-conseillers-departementaux-cd.csv   (4 037 élus, 95 départements, 11/08/2026)
  elus-conseillers-regionaux-cr.csv        (1 745 élus, 14 régions)
  elus-conseillers-communautaires-epci.csv (62 129 élus, 1 250 intercommunalités)

Vie privée (règle du site, 2026-09-09, la même que sync_rne_maires.py) : on ne
garde QUE la collectivité, le nom, le prénom, la fonction et les dates de
mandat et de fonction. La date de naissance, la catégorie socioprofessionnelle,
la nationalité et le sexe ne sont jamais chargés.

Une ligne = un élu ; `niveau` (departement, region, epci) et `code` (code du
département, code de la région, SIREN de l'intercommunalité) disent de quelle
collectivité. Le président et le nombre d'élus se calculent dans dbt.

État courant : table remplacée en entier quand l'un des trois fichiers change
(adresses et dates rangées dans la description), jamais par moins de 90 % des
élus actuels (_national_raw). NATIONAL_CHECK_ONLY=1 : la veille du mardi.

Usage :
    python scripts/sync/sync_rne_executifs.py
    python scripts/sync/sync_rne_executifs.py --dry-run
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _national_raw as NR  # noqa: E402

TABLE = "rne_executifs"
DATASET_API = "https://www.data.gouv.fr/api/1/datasets/repertoire-national-des-elus-1/"

# fichier → (niveau, colonne du code, colonne du libellé)
FICHIERS = {
    "conseillers-departementaux": ("departement", "Code du département", "Libellé du département"),
    "conseillers-regionaux": ("region", "Code de la région", "Libellé de la région"),
    "conseillers-communautaires": ("epci", "N° SIREN", "Libellé de l'EPCI"),
}
COMMUNS = {
    "Nom de l'élu": "nom",
    "Prénom de l'élu": "prenom",
    "Date de début du mandat": "date_debut_mandat",
    "Libellé de la fonction": "fonction",
    "Date de début de la fonction": "date_debut_fonction",
}
COLUMNS = ["niveau", "code", "libelle", *COMMUNS.values()]
BQ_SCHEMA = ",".join(f"{c}:STRING" for c in COLUMNS)
ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = ROOT / "cache" / "wip" / "national" / "rne"


def resources() -> dict[str, dict]:
    with urllib.request.urlopen(DATASET_API, timeout=60) as r:
        d = json.load(r)
    out = {}
    for key in FICHIERS:
        for res in d["resources"]:
            if key in (res.get("title") or "").lower():
                out[key] = {"url": res["url"], "last_modified": res.get("last_modified")}
                break
        else:
            raise SystemExit(f"fichier « {key} » introuvable dans le répertoire des élus")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    version = resources()
    if NR.is_version_current(TABLE, version) and not args.force:
        print(f"  = {TABLE} : versions déjà chargées — rien à faire")
        return 0
    print(f"→ RNE (conseils départementaux, régionaux, communautaires) → {NR.DATASET_ID}.{TABLE}")
    if args.dry_run or NR.CHECK_ONLY:
        if NR.CHECK_ONLY:
            NR.would_change(TABLE, ", ".join(f"{k} {v['last_modified']}" for k, v in version.items()))
        return 0
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    out = CACHE_DIR / "rne_executifs.csv"
    n = 0
    with open(out, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(COLUMNS)
        for key, (niveau, code_col, lib_col) in FICHIERS.items():
            raw = urllib.request.urlopen(version[key]["url"], timeout=600).read().decode("utf-8-sig", errors="replace")
            reader = csv.DictReader(io.StringIO(raw), delimiter=";")
            missing = [k for k in [code_col, lib_col, *COMMUNS] if k not in (reader.fieldnames or [])]
            if missing:
                raise SystemExit(f"{key} : colonnes attendues absentes : {missing}")
            k = 0
            for row in reader:
                w.writerow([niveau, (row.get(code_col) or "").strip(), (row.get(lib_col) or "").strip(),
                            *[(row.get(c) or "").strip() for c in COMMUNS]])
                k += 1
            print(f"  {key} : {k:,} élus")
            n += k
    print(f"  {n:,} élus, {len(COLUMNS)} colonnes (aucune donnée sensible) → {out.name}")
    NR.replace_snapshot(TABLE, out, BQ_SCHEMA, version=version,
                        load_args=("--source_format=CSV", "--skip_leading_rows=1", "--allow_quoted_newlines"), force=args.force)
    return 0


if __name__ == "__main__":
    sys.exit(main())
