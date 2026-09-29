#!/usr/bin/env python3
"""
Budget de l'État, dépenses par destination (PLF) → raw_national.etat_plf (2026-09-23).

Remplace sync_etat_lfi.py, qui connaissait ses années par cœur (un dataset et un
jeu de noms de colonnes par année, écrits dans le code) et écrivait dans
pipeline/cache/wip, que rien ne portait jusqu'au site.

Chaque mardi, la veille cherche dans le catalogue de data.economie.gouv.fr les
jeux « <plf|lfi><année>-depenses-<année>-selon-(nomenclatures-)destination » et
compare leur date de modification à celle qu'on a chargée. Une année nouvelle
se charge seule. Le ministère change les noms de colonnes d'une année à l'autre
(« autorisation_engagement » en 2025, « ae_plf » en 2024) : chaque rôle a sa
liste de noms connus ; si une année nouvelle n'en a aucun, le chargeur s'arrête
en nommant les colonnes trouvées — le mail d'échec du mardi le dit, rien de faux
n'est publié.

Une ligne = une ligne du jeu source (action × titre…), réduite aux colonnes
utiles : l'export (export_national_etat.py) agrège par mission et programme.

Constat du 23/09/2026 : le PLF 2026 n'a pas encore été publié dans ce format
(seuls le « budget vert » et la performance 2025 le sont) ; la page reste sur
2025, et passera à 2026 le mardi qui suit sa publication.
"""
from __future__ import annotations

import argparse
import csv
import gzip
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _national_raw as NR  # noqa: E402

TABLE = "etat_plf"
CATALOG = "https://data.economie.gouv.fr/api/explore/v2.1/catalog/datasets"
PATTERN = re.compile(r"^(plf|lfi)-?(?:20)?(\d{2})-depenses-(20\d{2})-selon-(?:nomenclatures-)?destination(?:-et-nature)?$")
FIRST_YEAR = 2024
COLUMNS = ["dataset_id", "exercice", "loi", "typebudget", "mission", "libelle_mission", "programme", "libelle_programme", "action", "libelle_action", "ae", "cp"]
BQ_SCHEMA = "dataset_id:STRING,exercice:INTEGER,loi:STRING,typebudget:STRING,mission:STRING,libelle_mission:STRING,programme:STRING,libelle_programme:STRING,action:STRING,libelle_action:STRING,ae:FLOAT,cp:FLOAT"

# Role → known source names, most recent format first.
ROLES = {
    "typebudget": ["typebudget", "type_budget", "type_mission"],
    "ae": ["autorisation_engagement", "autorisations_engagement", "ae_plf", "ae_lfi", "ae"],
    "cp": ["credit_de_paiement", "credits_de_paiement", "cp_plf", "cp_lfi", "cp"],
    "programme": ["programme", "code_programme"],
}

ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = ROOT / "cache" / "wip" / "national" / "etat"


def get(url: str) -> dict:
    with urlopen(Request(url, headers={"User-Agent": "Qipu/1.0"}), timeout=60) as r:
        return json.loads(r.read().decode("utf-8"))


def discover() -> dict[int, dict]:
    """{exercice: {id, modified, fields}} — the latest-modified dataset per year."""
    found: dict[int, dict] = {}
    offset = 0
    while True:
        q = urlencode({"where": 'search("depenses") and search("destination")', "limit": 100, "offset": offset})
        page = get(f"{CATALOG}?{q}")
        for r in page.get("results", []):
            m = PATTERN.match(r["dataset_id"])
            if not m or int(m.group(3)) < FIRST_YEAR:
                continue
            meta = (r.get("metas") or {}).get("default", {})
            year = int(m.group(3))
            cur = {"id": r["dataset_id"], "loi": m.group(1).upper(), "modified": meta.get("modified") or "",
                   "fields": [f["name"] for f in r.get("fields", [])]}
            # A year published twice (PLF, then LFI): the vote wins over the bill.
            if year not in found or (cur["loi"] == "LFI" and found[year]["loi"] != "LFI"):
                found[year] = cur
        offset += 100
        if offset >= page.get("total_count", 0):
            break
    return found


def mapping(fields: list[str]) -> dict[str, str]:
    """Which source column plays each role; raises with the fields found."""
    have = set(fields)
    out: dict[str, str] = {}
    for role, names in ROLES.items():
        hit = next((n for n in names if n in have), None)
        if hit is None:
            raise SystemExit(f"✗ colonne « {role} » introuvable parmi {sorted(have)} — ajouter son nom à ROLES")
        out[role] = hit
    # Mission: 2024 puts the code in « code_mission » and the label in « mission »;
    # 2025 puts the code in « mission » and the label in « libelle_mission ».
    if "code_mission" in have:
        out["mission"], out["libelle_mission"] = "code_mission", "mission"
    elif "mission" in have:
        out["mission"], out["libelle_mission"] = "mission", "libelle_mission" if "libelle_mission" in have else "mission"
    else:
        raise SystemExit(f"✗ colonne « mission » introuvable parmi {sorted(have)}")
    out["libelle_programme"] = "libelle_programme" if "libelle_programme" in have else out["programme"]
    # The action level feeds the simulator's breakdown (build_drilldown_etat_actions.py).
    out["action"] = next((n for n in ("action", "code_action") if n in have), "")
    out["libelle_action"] = next((n for n in ("libelle_action",) if n in have), "")
    return out


def records(dataset_id: str) -> list[dict]:
    """All rows through the export endpoint (no 10 000-row paging limit)."""
    url = f"{CATALOG}/{dataset_id}/exports/json"
    with urlopen(Request(url, headers={"User-Agent": "Qipu/1.0"}), timeout=300) as r:
        body = r.read()
    # The portal sometimes gzips the export without being asked.
    if body[:2] == b"\x1f\x8b":
        body = gzip.decompress(body)
    return json.loads(body.decode("utf-8"))


def code(v) -> str:
    """« 150 », « 150.0 » and 150 are the same programme."""
    if v is None:
        return "?"
    s = str(v).strip()
    return str(int(float(s))) if re.fullmatch(r"\d+(\.0+)?", s) else s


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    found = discover()
    if not found:
        raise SystemExit("✗ aucun jeu « dépenses selon destination » au catalogue — le motif de nom a-t-il changé ?")
    version = {str(y): {"id": d["id"], "modified": d["modified"]} for y, d in sorted(found.items())}
    for y, d in sorted(found.items()):
        mapping(d["fields"])  # a new year with unknown columns stops here, in the check too
    if NR.is_version_current(TABLE, version) and not args.force:
        print(f"  = {TABLE} : {', '.join(map(str, sorted(found)))} déjà chargés — rien à faire")
        return 0
    old = (NR.meta(TABLE).get("version") or {})
    changed = [y for y in version if old.get(y) != version[y]]
    print(f"→ Budget de l'État → {NR.DATASET_ID}.{TABLE} — nouveau ou modifié : {', '.join(changed)}")
    if args.dry_run or NR.CHECK_ONLY:
        if NR.CHECK_ONLY:
            NR.would_change(TABLE, ", ".join(f"{y} ({version[y]['id']})" for y in changed))
        return 0

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    out = CACHE_DIR / "etat_plf.csv"
    n = 0
    with open(out, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        w.writeheader()
        for year, d in sorted(found.items()):
            m = mapping(d["fields"])
            rows = records(d["id"])
            if not rows:
                raise SystemExit(f"✗ {d['id']} : aucune ligne — table inchangée")
            for r in rows:
                w.writerow({
                    "dataset_id": d["id"], "exercice": year, "loi": d["loi"],
                    "typebudget": r.get(m["typebudget"]) or "",
                    "mission": code(r.get(m["mission"])), "libelle_mission": r.get(m["libelle_mission"]) or "?",
                    "programme": code(r.get(m["programme"])), "libelle_programme": r.get(m["libelle_programme"]) or "?",
                    # Action codes keep their leading zero (« 01 ») : no code() here.
                    "action": str(r.get(m["action"]) or "").strip() if m["action"] else "",
                    "libelle_action": (r.get(m["libelle_action"]) or "").strip() if m["libelle_action"] else "",
                    "ae": r.get(m["ae"]) or 0, "cp": r.get(m["cp"]) or 0,
                })
            n += len(rows)
            print(f"  {year} ({d['id']}) : {len(rows):,} lignes")
    NR.replace_snapshot(TABLE, out, BQ_SCHEMA, version=version,
                        load_args=("--source_format=CSV", "--skip_leading_rows=1", "--allow_quoted_newlines"), force=args.force)
    print(f"✓ {n:,} lignes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
