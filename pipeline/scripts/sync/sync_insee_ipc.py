#!/usr/bin/env python3
"""
National ingest — indice des prix à la consommation (Insee) → raw_national.insee_ipc.

Pourquoi (2026-09-25) : la fiche « évolution » d'une commune compare un chiffre
de 2019 à celui de 2025 ; sur six ans, les prix ont bougé, et le lecteur doit
pouvoir le savoir sans qu'on le calcule à sa place. La fiche dit « les prix à
la consommation ont augmenté de X % entre 2019 et 2025 (Insee) », rien de plus.

Source : Insee, Banque de données macroéconomiques, série 001759970 (IPC,
base 2015, ensemble des ménages, France, ensemble), mensuelle, API SDMX
ouverte sans clé. Licence ouverte.

Garde : table remplacée seulement si la série a changé (_national_raw).

Usage :
    python scripts/sync/sync_insee_ipc.py
"""
from __future__ import annotations

import csv
import re
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _national_raw as NR  # noqa: E402

TABLE = "insee_ipc"
SERIE = "001759970"
URL = f"https://bdm.insee.fr/series/sdmx/data/SERIES_BDM/{SERIE}"
BQ_SCHEMA = "serie:STRING,periode:STRING,valeur:FLOAT"
ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = ROOT / "cache" / "wip" / "national" / "insee_ipc"


def main() -> int:
    with urllib.request.urlopen(URL, timeout=60) as r:
        xml = r.read().decode("utf-8")
    obs = re.findall(r'TIME_PERIOD="([^"]+)" OBS_VALUE="([^"]+)"', xml)
    if len(obs) < 120:
        raise SystemExit(f"✗ série {SERIE} : {len(obs)} points seulement — rien n'est remplacé")
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    out = CACHE_DIR / "insee_ipc.csv"
    with out.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["serie", "periode", "valeur"])
        for p, v in sorted(obs):
            w.writerow([SERIE, p, v])
    last = max(p for p, _ in obs)
    print(f"  {len(obs)} mois, jusqu'à {last} → {out.name}")
    # Same contract as every sync (26/09: the check-only run failed here): nothing is written in
    # check mode — only « would change » when the series has a newer month than the table.
    res = {"url": URL, "last_modified": last}
    if NR.is_version_current(TABLE, res):
        print(f"  = {TABLE} : jusqu'à {last} déjà chargé — rien à faire")
        return 0
    if NR.CHECK_ONLY:
        NR.would_change(TABLE, f"jusqu'à {last}")
        return 0
    NR.replace_snapshot(TABLE, out, BQ_SCHEMA, version={"url": URL, "last_modified": last},
                        load_args=("--source_format=CSV", "--skip_leading_rows=1"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
