#!/usr/bin/env python3
"""Sync brut des AP/CP du compte administratif (exécution d'investissement).

Source : opendata.paris.fr. La Ville publie la MÊME série en DEUX jeux de
données, coupés au changement de plan comptable, avec des champs identiques :

  M14  `comptes-administratifs-autorisations-de-programmes-ap-ville-departement`
       exercices 2009-2017 (~28 000 lignes)
  M57  `comptes-administratifs-autorisations-de-programmes-a-partir-de-2018-m57-ville-de`
       exercices 2018+ (~7 500 lignes)

Les deux partagent `autorisation_de_programme_cle` : une opération commencée en
2016 se poursuit sous la même clé après 2018. Ne synchroniser que le premier
coupait toute opération au 31 décembre 2017 — la rénovation du Châtelet
s'arrêtait à 2,9 M€ alors que 27,8 M€ ont été mandatés ensuite (constaté
2026-09-10).

Chaque ligne porte une autorisation de programme × exercice × nature, avec
`mandate_titre_apres_regul` = la dépense RÉELLEMENT mandatée. C'est la seule
source publique de dépense d'investissement constatée par opération —
l'exécution par marché, elle, n'est pas publiée.

Couche RAW uniquement : on télécharge tout, verbatim, sans filtrage ni
transformation (le typage vit en stg, le rattachement aux lieux dans la chaîne
gather → juge). Sorties : pipeline/cache/ap_cp/ap_cp_raw.jsonl (M14) et
ap_cp_m57_raw.jsonl (M57), chacun avec son _meta.json.

Usage : python pipeline/scripts/sync/sync_ap_cp.py            # les deux
        python pipeline/scripts/sync/sync_ap_cp.py --plan m57  # un seul
"""
from __future__ import annotations

import json
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT_DIR = ROOT / "pipeline" / "cache" / "ap_cp"

# Les deux moitiés de la même série, cf. docstring. `stem` nomme les fichiers de
# sortie ; l'export les relit tous les deux.
PLANS = {
    "m14": {"dataset": "comptes-administratifs-autorisations-de-programmes-ap-ville-departement",
            "stem": "ap_cp_raw"},
    "m57": {"dataset": "comptes-administratifs-autorisations-de-programmes-a-partir-de-2018-m57-ville-de",
            "stem": "ap_cp_m57_raw"},
}
DATASET = PLANS["m14"]["dataset"]   # valeur par défaut, réécrite par main()
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _paris_portal  # noqa: E402
BASE = _paris_portal.api(f"/catalog/datasets/{DATASET}")
UA = {"User-Agent": "qipu/0.1 (recherche civique; qipu.org)"}
PAGE = 100          # limite ODS par requête en /records
MAX_OFFSET = 10000  # l'API explore plafonne offset+limit ; au-delà on segmente


def get(url: str, tries: int = 4) -> dict:
    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers=UA)
            return json.loads(urllib.request.urlopen(req, timeout=45).read())
        except Exception as exc:  # noqa: BLE001 — retry sur tout transport
            last = exc
            time.sleep(2 * (i + 1))
    raise last if last else RuntimeError("unreachable")


def facet_values(field: str) -> list[str]:
    # `exercice_comptable` est un champ DATE (2009-01-01T00:00:00) : on en tire
    # l'année, et le where du fetch utilise year(...) — l'égalité chaîne renvoie
    # un 400. Chaque jeu couvre sa propre plage (M14 2009-2017, M57 2018+) ;
    # on lit la plage plutôt que de la coder en dur.
    j = get(f"{BASE}/records?" + urllib.parse.urlencode(
        {"select": f"{field}, count(*) as n", "group_by": field, "limit": "100"}))
    return sorted({str(r[field])[:4] for r in j.get("results", []) if r.get(field)})


def fetch_where(where: str) -> list[dict]:
    rows, offset = [], 0
    while True:
        j = get(f"{BASE}/records?" + urllib.parse.urlencode(
            {"limit": str(PAGE), "offset": str(offset), "where": where}))
        batch = j.get("results", [])
        rows.extend(batch)
        offset += PAGE
        if len(batch) < PAGE:
            break
        if offset >= MAX_OFFSET:
            print(f"  ⚠ segment {where!r} touche le plafond d'offset — segmenter plus fin", file=sys.stderr)
            break
        time.sleep(0.25)
    return rows


def sync_plan(plan: str) -> tuple[int, int]:
    """Télécharge un jeu, exercice par exercice. Retourne (téléchargé, annoncé)."""
    global DATASET, BASE
    DATASET = PLANS[plan]["dataset"]
    BASE = _paris_portal.api(f"/catalog/datasets/{DATASET}")
    stem = PLANS[plan]["stem"]

    total_attendu = get(f"{BASE}/records?limit=0").get("total_count")
    # Segmentation par exercice : chaque tranche reste très en dessous du
    # plafond d'offset de l'API, et le sync est rejouable exercice par exercice.
    exercices = sorted(facet_values("exercice_comptable"))
    print(f"[{plan}] total annoncé : {total_attendu} · exercices : "
          f"{exercices[0]}→{exercices[-1]} ({len(exercices)})")

    out = OUT_DIR / f"{stem}.jsonl"
    n = 0
    with out.open("w") as f:
        for ex in exercices:
            rows = fetch_where(f"year(exercice_comptable)={ex}")
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
            n += len(rows)
            print(f"  {ex}: {len(rows)} lignes (cumul {n})", flush=True)

    (OUT_DIR / f"{stem.replace('_raw', '')}_meta.json").write_text(json.dumps({
        "plan_comptable": plan.upper(),
        "dataset": DATASET,
        "source_url": f"https://opendata.paris.fr/explore/dataset/{DATASET}/",
        "total_annonce": total_attendu,
        "total_telecharge": n,
        "synced_at": datetime.now(timezone.utc).isoformat(),
    }, ensure_ascii=False, indent=1))
    statut = "OK" if n == total_attendu else f"ÉCART ({n} ≠ {total_attendu})"
    print(f"[{plan}] {statut} → {out.relative_to(ROOT)}")
    return n, total_attendu


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", choices=[*PLANS, "all"], default="all",
                    help="m14 (2009-2017), m57 (2018+) ou all")
    args = ap.parse_args()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    plans = list(PLANS) if args.plan == "all" else [args.plan]
    ok = True
    for p in plans:
        n, attendu = sync_plan(p)
        ok = ok and n == attendu
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
