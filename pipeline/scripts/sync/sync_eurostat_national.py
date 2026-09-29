#!/usr/bin/env python3
"""
Eurostat → raw_national.eurostat_series (2026-09-23).

Les pages nationales (/dette, /fiscalite, /budget, le simulateur) lisent cinq
jeux Eurostat. Quatre scripts les téléchargeaient et fabriquaient chacun son
JSON, dans pipeline/cache/wip/national depuis la mise en couches de mai : plus
rien ne les portait jusqu'au site, figé sur les chiffres du 8 mai. Ce chargeur
les remplace côté source : une table, une ligne par valeur, et la chaîne
habituelle (stg → core → mart → export_national_eurostat.py) refait les
fichiers des pages.

Les tranches (une requête par jeu, l'union de ce que lisaient les anciens
scripts) :
    gov_10q_ggdebt  dette trimestrielle (GD), S13/S1311/S1313/S1314, % PIB et M€, 6 pays
    gov_10a_taxag   prélèvements (S13), 8 postes dont le total, % PIB et M€, 6 pays, 2010→
    gov_10a_exp     dépenses COFOG (S13, TE), 10 fonctions + total, % PIB, 6 pays, 2018→
    gov_10a_main    dépenses par sous-secteur (TE), S13/S1311/S1312/S1313/S1314, % PIB, FR, 2018→
    nama_10_gdp     PIB (B1GQ) à prix courants, M€, FR, 2018→

Et, depuis le 2026-09-24, les recettes publiques du panneau de /budget (qui
était une compilation tapée à la main, seed_recettes_apu.csv) — deux requêtes
de plus, rangées sous leur propre nom pour ne pas se mêler aux tranches
ci-dessus (les exports lisent ces jeux sans filtrer secteur ni poste) :
    gov_10a_taxag:fr  impôts détaillés (accises, mutations, assurances, foncier,
                      salaires) par sous-secteur S1311/S1313/S1314, M€, FR, 2018→
    gov_10a_main:fr   recettes (TR) et leurs composantes, dépenses (TE), solde
                      (B9), S13/S1311/S1313/S1314, M€, FR, 2018→
Le nom avant « : » est le jeu Eurostat interrogé.

Version : la date « updated » de chaque jeu (Eurostat la renvoie avec les
données) et l'empreinte des tranches demandées ; la table n'est remplacée que
si l'une des deux a changé. En veille (NATIONAL_CHECK_ONLY=1), seules les
dates sont lues.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import sys
import time
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _national_raw as NR  # noqa: E402

TABLE = "eurostat_series"
API = "https://ec.europa.eu/eurostat/api/dissemination/statistics/1.0/data/"
PEERS = ["FR", "DE", "IT", "ES", "NL", "EU27_2020"]
DIMS = ["geo", "time", "unit", "sector", "na_item", "cofog99"]
BQ_SCHEMA = "dataset:STRING,geo:STRING,time:STRING,unit:STRING,sector:STRING,na_item:STRING,cofog99:STRING,value:FLOAT,updated:STRING"
TOTAL_PO = "D2_D5_D91_D61_M_D612_M_D614_M_D995"

QUERIES: dict[str, list[tuple[str, str]]] = {
    "gov_10q_ggdebt": [("na_item", "GD")]
    + [("sector", s) for s in ("S13", "S1311", "S1313", "S1314")]
    + [("unit", u) for u in ("PC_GDP", "MIO_EUR")]
    + [("geo", g) for g in PEERS],
    "gov_10a_taxag": [("sector", "S13"), ("sinceTimePeriod", "2010")]
    + [("na_item", c) for c in ("D211", "D2", "D51A", "D51B", "D5", "D61", "D91", TOTAL_PO)]
    + [("unit", u) for u in ("PC_GDP", "MIO_EUR")]
    + [("geo", g) for g in PEERS],
    "gov_10a_exp": [("unit", "PC_GDP"), ("sector", "S13"), ("na_item", "TE"), ("sinceTimePeriod", "2018")]
    + [("cofog99", c) for c in [f"GF{i:02d}" for i in range(1, 11)] + ["TOTAL"]]
    + [("geo", g) for g in PEERS],
    "gov_10a_main": [("unit", "PC_GDP"), ("na_item", "TE"), ("geo", "FR"), ("sinceTimePeriod", "2018")]
    + [("sector", s) for s in ("S13", "S1311", "S1312", "S1313", "S1314")],
    "nama_10_gdp": [("unit", "CP_MEUR"), ("na_item", "B1GQ"), ("geo", "FR"), ("sinceTimePeriod", "2018")],
    # Recettes publiques (/budget, simulateur) — export_national_eurostat.build_recettes.
    "gov_10a_taxag:fr": [("geo", "FR"), ("unit", "MIO_EUR"), ("sinceTimePeriod", "2018")]
    + [("sector", s) for s in ("S1311", "S1313", "S1314")]
    + [("na_item", c) for c in ("D214A", "D214C", "D214G", "D29A", "D29C")],
    "gov_10a_main:fr": [("geo", "FR"), ("unit", "MIO_EUR"), ("sinceTimePeriod", "2018")]
    + [("sector", s) for s in ("S13", "S1311", "S1313", "S1314")]
    + [("na_item", c) for c in ("TR", "TE", "B9", "P11_P12_P131", "D21REC", "D211REC", "D29REC", "D39REC", "D4REC",
                                "D5REC", "D51A_C1REC", "D51B_C2REC", "D61REC", "D611REC", "D613REC",
                                "D7REC", "D73REC", "D9REC", "D91REC")],
}

ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = ROOT / "cache" / "wip" / "national" / "eurostat"


def fetch(dataset: str, params: list[tuple[str, str]]) -> dict:
    # « gov_10a_main:fr » : une seconde requête sur le même jeu Eurostat.
    url = f"{API}{dataset.split(':')[0]}?{urlencode([('format', 'JSON'), *params])}"
    for attempt in range(3):
        try:
            with urlopen(Request(url, headers={"User-Agent": "Qipu/1.0"}), timeout=120) as r:
                return json.loads(r.read().decode("utf-8"))
        except Exception:
            if attempt == 2:
                raise
            time.sleep(5 * (attempt + 1))
    raise RuntimeError("unreachable")


def flatten(dataset: str, data: dict) -> list[dict]:
    """JSON-stat 2.0 → one dict per value, with the dimensions we keep."""
    order, sizes, dims = data["id"], data["size"], data["dimension"]
    inv = {}
    for d in order:
        idx = dims[d]["category"]["index"]
        inv[d] = {p: c for c, p in idx.items()} if isinstance(idx, dict) else dict(enumerate(idx))
    strides = [1] * len(sizes)
    for i in range(len(sizes) - 2, -1, -1):
        strides[i] = strides[i + 1] * sizes[i + 1]
    rows = []
    for flat, val in (data.get("value") or {}).items():
        rem, coords = int(flat), {}
        for i, d in enumerate(order):
            coords[d] = inv[d][rem // strides[i]]
            rem %= strides[i]
        rows.append({"dataset": dataset, **{d: coords.get(d, "") for d in DIMS}, "value": val, "updated": data.get("updated", "")})
    return rows


def spec_hash() -> str:
    return hashlib.sha256(json.dumps(QUERIES, sort_keys=True).encode()).hexdigest()[:12]


def updated_stamps() -> dict[str, str]:
    """Each dataset's publication stamp, from a one-period request."""
    out = {}
    for ds, params in QUERIES.items():
        light = [(k, v) for k, v in params if k != "sinceTimePeriod"]
        out[ds] = fetch(ds, [*light, ("lastTimePeriod", "1")]).get("updated", "")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    stamps = updated_stamps()
    version = {"datasets": stamps, "spec": spec_hash()}
    if NR.is_version_current(TABLE, version) and not args.force:
        print(f"  = {TABLE} : versions Eurostat inchangées — rien à faire")
        return 0
    changed = [d for d, s in stamps.items() if (NR.meta(TABLE).get("version") or {}).get("datasets", {}).get(d) != s]
    print(f"→ Eurostat → {NR.DATASET_ID}.{TABLE} — nouveau : {', '.join(changed) or 'tranches demandées'}")
    if args.dry_run or NR.CHECK_ONLY:
        if NR.CHECK_ONLY:
            NR.would_change(TABLE, ", ".join(changed) or "tranches demandées")
        return 0

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    out = CACHE_DIR / "eurostat_series.csv"
    n = 0
    with open(out, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["dataset", *DIMS, "value", "updated"])
        w.writeheader()
        for ds, params in QUERIES.items():
            rows = flatten(ds, fetch(ds, params))
            if not rows:
                raise SystemExit(f"✗ {ds} : aucune valeur — table inchangée")
            w.writerows(rows)
            n += len(rows)
            print(f"  {ds} : {len(rows):,} valeurs")
    NR.replace_snapshot(TABLE, out, BQ_SCHEMA, version=version,
                        load_args=("--source_format=CSV", "--skip_leading_rows=1"), force=args.force)
    print(f"✓ {n:,} valeurs Eurostat")
    return 0


if __name__ == "__main__":
    sys.exit(main())
