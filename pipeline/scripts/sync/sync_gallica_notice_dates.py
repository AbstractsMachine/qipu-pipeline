#!/usr/bin/env python3
"""La date de chaque fascicule du Bulletin municipal qu'on publie, lue dans SA notice Gallica.

Pourquoi ce raccourci plutôt qu'une resynchro complète. Après la correction du
parseur SRU (sync_gallica_bmo.py, 2026-09-13), il fallait redater les extraits
déjà publiés. Resynchroniser les listes de fascicules de 129 lieux demande
jusqu'à 40 pages de résultats par lieu, soit une à deux journées de requêtes.
Or seuls les extraits GARDÉS sont publiés : 215 fascicules distincts. La notice
Dublin Core de chaque document (`services/OAIRecord`) donne sa date sans
passer par une liste de résultats, donc sans risque d'appariement.

Validé avant usage : sur les 8 fascicules de la piscine des Amiraux, la date de
la notice est identique à celle du parseur corrigé, et différente de l'ancienne
dans les 8 cas.

Sortie (archive brute, comme le reste de la couche Gallica) :
    pipeline/cache/lieux/bmo_dates_notice.json
    {"ark:/12148/bpt6k…": {"date": "1927-12-18", "source": "<url notice>", "lu_le": "…"}}

Reprise : un ark déjà lu n'est pas redemandé, sauf avec --refresh.

Usage :
    python pipeline/scripts/sync/sync_gallica_notice_dates.py [--refresh]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CACHE = ROOT / "pipeline" / "cache" / "lieux"
OUT = CACHE / "bmo_dates_notice.json"
UA = {"User-Agent": "qipu/0.1 (recherche civique; qipu.org)"}
NOTICE = "https://gallica.bnf.fr/services/OAIRecord?"
DATE = re.compile(r"<dc:date>([^<]+)</dc:date>")


def arks_gardes() -> set[str]:
    """Les fascicules dont un extrait est publié : ceux des fichiers keep."""
    arks: set[str] = set()
    for p in CACHE.glob("*_bmo_keep.json"):
        try:
            for k in json.load(p.open()).get("keep") or []:
                if (k.get("ark") or "").startswith("ark:"):
                    arks.add(k["ark"])
        except Exception:
            continue
    return arks


def date_notice(ark: str) -> tuple[str, str]:
    url = NOTICE + urllib.parse.urlencode({"ark": ark})
    for essai in range(4):
        try:
            xml = urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60).read()
            m = DATE.search(xml.decode("utf-8", "ignore"))
            return (m.group(1).strip() if m else ""), url
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            if essai == 3:
                raise
            time.sleep(6 * (essai + 1))
    return "", url


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--refresh", action="store_true", help="relire aussi les arks déjà datés")
    args = ap.parse_args()

    connues = json.load(OUT.open()) if OUT.exists() else {}
    arks = sorted(arks_gardes())
    a_lire = [a for a in arks if args.refresh or not connues.get(a, {}).get("date")]
    print(f"{len(arks)} fascicules publiés, {len(a_lire)} à lire")

    erreurs = 0
    for i, ark in enumerate(a_lire, 1):
        try:
            date, url = date_notice(ark)
        except Exception as exc:
            erreurs += 1
            print(f"ERR {ark}: {type(exc).__name__}", file=sys.stderr)
            continue
        connues[ark] = {"date": date, "source": url, "lu_le": datetime.now(timezone.utc).isoformat()}
        if i % 20 == 0 or i == len(a_lire):
            OUT.write_text(json.dumps(connues, ensure_ascii=False, indent=1))  # reprise possible
            print(f"  {i}/{len(a_lire)}", flush=True)
        time.sleep(1.5)  # politesse Gallica

    OUT.write_text(json.dumps(connues, ensure_ascii=False, indent=1))
    sans = sum(1 for a in arks if not connues.get(a, {}).get("date"))
    print(f"→ {OUT.name} : {len(arks) - sans} datés, {sans} sans date, {erreurs} erreurs réseau")
    return 1 if erreurs else 0


if __name__ == "__main__":
    raise SystemExit(main())
