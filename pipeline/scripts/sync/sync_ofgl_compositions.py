#!/usr/bin/env python3
"""
OFGL « détail des compositions intercommunales » → raw_national.ofgl_compositions.

Pourquoi (2026-09-26). L'échelle des niveaux relie chaque commune à son
intercommunalité (et, par elle, à son département et à sa région). L'OFGL
publie chaque année la composition de toutes les intercommunalités à fiscalité
propre : une ligne par commune et par année, avec le SIREN et le nom de
l'intercommunalité (35 004 communes → 1 216 intercommunalités en 2025, aucune
commune sans intercommunalité — mesuré le 2026-09-26).

Le jeu change d'identifiant chaque année (detail_compositions_intercommunales_
2012_2025, puis …_2012_2026) : le script cherche le plus récent au catalogue
et n'en garde que la dernière année — c'est un état courant, chargé par
_national_raw.replace_snapshot (même garde de volume que le répertoire des
élus). La version source (identifiant du jeu + date de modification) est
écrite dans la description de la table : tant qu'elle ne change pas, rien
n'est téléchargé. NATIONAL_CHECK_ONLY=1 : la veille du mardi.

Usage:
    python scripts/sync/sync_ofgl_compositions.py
    python scripts/sync/sync_ofgl_compositions.py --dry-run
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from urllib.parse import urlencode

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _national_raw as NR  # noqa: E402

TABLE = "ofgl_compositions"
CATALOG = "https://data.ofgl.fr/api/explore/v2.1/catalog/datasets"
ID_RE = re.compile(r"^detail_compositions_intercommunales_2012_(\d{4})$")
COLS = [
    ("annee", "INTEGER"), ("insee", "STRING"), ("siren", "STRING"), ("nom", "STRING"),
    ("pmun", "INTEGER"), ("ptot", "INTEGER"), ("siren_epci", "STRING"), ("nom_epci", "STRING"),
]
ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = ROOT / "cache" / "wip" / "national" / "ofgl-compositions"


def latest_dataset() -> tuple[str, int, str]:
    url = CATALOG + "?" + urlencode({"where": 'search("detail_compositions_intercommunales")', "limit": 100})
    r = requests.get(url, timeout=60)
    r.raise_for_status()
    found = []
    for d in r.json().get("results", []):
        m = ID_RE.match(d["dataset_id"])
        if m:
            found.append((int(m.group(1)), d["dataset_id"], d["metas"]["default"].get("modified") or ""))
    if not found:
        raise SystemExit("✗ aucun jeu detail_compositions_intercommunales_2012_AAAA au catalogue OFGL")
    year, ds, modified = max(found)
    return ds, year, modified


def main() -> int:
    ap = argparse.ArgumentParser(description="Compositions intercommunales (dernière année) → raw_national")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    ds, year, modified = latest_dataset()
    version = {"dataset": ds, "modified": modified}
    if NR.is_version_current(TABLE, version) and not args.force:
        print(f"  = {TABLE} : {ds} ({modified[:10]}) déjà chargé — rien à faire")
        return 0
    print(f"→ {ds} (année {year}, modifié {modified[:10]}) → {NR.DATASET_ID}.{TABLE}")
    if args.dry_run or NR.CHECK_ONLY:
        if NR.CHECK_ONLY:
            NR.would_change(TABLE, f"{ds} {modified[:10]}")
        return 0

    where = f"year(annee)={year}"
    count = requests.get(f"{CATALOG}/{ds}/records?" + urlencode({"where": where, "limit": 0}), timeout=60)
    count.raise_for_status()
    expected = int(count.json()["total_count"])

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    out = CACHE_DIR / f"compositions_{year}.csv"
    select = "annee,insee,siren,nom,pmun,ptot,siren_epci,nom_epci"
    url = f"{CATALOG}/{ds}/exports/csv?" + urlencode(
        {"where": where, "select": select, "delimiter": ";", "use_labels": "false"}
    )
    with requests.get(url, stream=True, timeout=600) as resp:
        resp.raise_for_status()
        out.write_bytes(resp.content)
    rows = max(out.read_bytes().count(b"\n") - 1, 0)
    if rows != expected:
        raise NR.GuardError(f"✗ {rows:,} lignes exportées pour {expected:,} annoncées — table inchangée")
    schema = ",".join(f"{c}:{t}" for c, t in COLS)
    NR.replace_snapshot(TABLE, out, schema, version=version,
                        load_args=("--source_format=CSV", "--skip_leading_rows=1", "--field_delimiter=;"),
                        force=args.force)
    print(f"✓ {rows:,} communes, année {year}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
