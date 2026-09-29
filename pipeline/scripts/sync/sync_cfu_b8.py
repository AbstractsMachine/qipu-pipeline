#!/usr/bin/env python3
"""
National ingest — subventions nominatives des communes (annexe B8 du compte
financier unique, ou B1.7 / B8 du compte administratif et du budget primitif)
→ raw_national.cfu_b8_lignes.

Pourquoi (2026-09-25) : « à qui va l'argent » s'arrête aux catégories dans les
données ouvertes nationales (comptes 657x) ; le nom de chaque association ou
organisme aidé n'existe que dans les annexes des documents budgétaires de la
commune. Une passe de recherche (qipu-comms/cfu-national : pass1.py, pass2.py)
a trouvé ces documents sur les sites des communes de 3 500 habitants et plus et
en a extrait la liste B8 : un fichier JSON par commune (b8/<insee>.json), avec
le document, l'année et l'adresse d'origine dans etat.jsonl.

Jamais de personne physique : l'extraction les écarte, et ce script écarte
encore toute ligne dont la catégorie dit « physique ».

Garde : la table n'est remplacée que si le nouveau lot a au moins 90 % des
lignes de l'ancien (_national_raw) ; zéro ligne → erreur, rien n'est remplacé.

Usage :
    python scripts/sync/sync_cfu_b8.py                     # ~/code/qipu-comms/cfu-national
    python scripts/sync/sync_cfu_b8.py --dir /chemin/cfu-national
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _national_raw as NR  # noqa: E402

TABLE = "cfu_b8_lignes"
BQ_SCHEMA = ("code_insee:STRING,doc_type:STRING,annee:INTEGER,source_url:STRING,rang:INTEGER,"
             "nom:STRING,numeraire:FLOAT,nature:STRING,categorie:STRING,type_ligne:STRING")
ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = ROOT / "cache" / "wip" / "national" / "cfu_b8"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", type=Path, default=Path.home() / "code" / "qipu-comms" / "cfu-national")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    b8 = args.dir / "b8"
    etat = {}
    for line in (args.dir / "etat.jsonl").read_text(encoding="utf-8").splitlines():
        r = json.loads(line)
        etat[r["code_insee"]] = r
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    out = CACHE_DIR / "cfu_b8_lignes.csv"
    n = communes = ecartees = 0
    with out.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow([c.split(":")[0] for c in BQ_SCHEMA.split(",")])
        for p in sorted(b8.glob("*.json")):
            insee = p.stem
            meta = etat.get(insee) or {}
            rows = json.loads(p.read_text(encoding="utf-8"))
            if not rows:
                continue
            communes += 1
            doc = (meta.get("doctype") or "").upper() or None
            annee = meta.get("year")
            for i, r in enumerate(rows):
                cat = r.get("categorie") or ""
                if "physique" in cat.lower():
                    ecartees += 1
                    continue
                w.writerow([insee, doc, annee, meta.get("url"), i, (r.get("nom") or "").strip(),
                            r.get("numeraire"), (r.get("nature") or "").strip() or None, cat or None,
                            r.get("type") or "ligne"])
                n += 1
    if n == 0:
        raise SystemExit("✗ aucune ligne B8 — rien n'est remplacé")
    print(f"  {n:,} lignes, {communes} communes ({ecartees} lignes « personne physique » écartées) → {out.name}")
    NR.replace_snapshot(TABLE, out, BQ_SCHEMA, version={"url": str(b8), "last_modified": str(max(p.stat().st_mtime for p in b8.glob('*.json')))},
                        load_args=("--source_format=CSV", "--skip_leading_rows=1", "--allow_quoted_newlines"), force=args.force)
    return 0


if __name__ == "__main__":
    sys.exit(main())
