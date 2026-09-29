#!/usr/bin/env python3
"""Sync ciblé Gallica — Bulletin Municipal Officiel de la Ville de Paris.

Le BMO (débats et décisions du conseil municipal) est numérisé sur Gallica
de 1882 à 1985 (périodique ark cb343512457, vérifié 2026-07-17 : la
recherche plein-texte par fascicule répond via SRU avec
`collapsing=disabled` — « piscine des Amiraux » → 741 fascicules datés).

Écrit une ligne JSONL par fascicule où le lieu est mentionné : date du
fascicule, ark, URL Gallica. Raw only — la sélection éditoriale des
fascicules significatifs est un enrichissement séparé, cité page à page.

Usage :
    python pipeline/scripts/sync/sync_gallica_bmo.py
    python pipeline/scripts/sync/sync_gallica_bmo.py --query "Théâtre de la Ville" --slug theatre-de-la-ville
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

SRU = "https://gallica.bnf.fr/SRU"
BMO_ARK = "cb343512457_date"
UA = {"User-Agent": "qipu/0.1 (recherche civique; qipu.org)"}
ROOT = Path(__file__).resolve().parents[3]
OUT_DIR = ROOT / "pipeline" / "cache" / "lieux"
SEED = ROOT / "pipeline" / "seeds" / "seed_lieux_v1.csv"


def seed_targets() -> dict[str, list[str]]:
    """Un lieu = toutes ses requêtes : `bmo_query` + chaque nom de
    `noms_historiques` (séparés par `;`). L'audit 2026-07-20 a montré le coût
    de l'oubli : le Châtelet requêté sous un seul nom (50 fascicules en cache
    contre 2 819 à la source), la place de la Nation jamais cherchée sous
    « place du Trône » — le nom qu'emploie tout le XIXe siècle."""
    out: dict[str, list[str]] = {}
    for r in csv.DictReader(SEED.open()):
        qs = [(r.get("bmo_query") or r["name"]).strip()]
        qs += [n.strip() for n in (r.get("noms_historiques") or "").split(";") if n.strip()]
        out[r["slug"]] = qs
    return out

# Un enregistrement SRU à la fois, PUIS l'identifiant et la date à l'intérieur.
#
# L'ancienne expression cherchait l'identifiant puis « la première date qui
# suit », et rien ne l'empêchait de franchir la fin de l'enregistrement. Prouvé
# le 2026-09-13 sur un XML fabriqué : un enregistrement sans date recevait la
# date du SUIVANT, qui disparaissait ; une date écrite avant l'identifiant
# décalait tout, un fascicule sur deux perdu. Symptôme publié : un Bulletin
# « de 1912 » regrettant la démolition d'une piste cycliste survenue en 1967.
REC_BLOC = re.compile(r"<srw:record>(.*?)</srw:record>", re.S)
REC_ID = re.compile(r"<dc:identifier>([^<]+)</dc:identifier>")
REC_DATE = re.compile(r"<dc:date>([^<]+)</dc:date>")


def records(xml: str) -> list[dict]:
    """Les fascicules d'une page SRU, chacun avec SA date. Un enregistrement
    sans date garde une date vide plutôt que d'emprunter celle du voisin."""
    out = []
    for bloc in REC_BLOC.findall(xml):
        ident = REC_ID.search(bloc)
        if not ident:
            continue
        date = REC_DATE.search(bloc)
        out.append({"gallica_url": ident.group(1).strip(),
                    "issue_date": date.group(1).strip() if date else ""})
    return out
NUM_RE = re.compile(r"<srw:numberOfRecords>(\d+)</srw:numberOfRecords>")


def sru(query: str, start: int, count: int = 50) -> str:
    params = {
        "operation": "searchRetrieve",
        "version": "1.2",
        "query": f'(gallica all "{query}") and (arkPress all "{BMO_ARK}")',
        "collapsing": "disabled",
        "startRecord": str(start),
        "maximumRecords": str(count),
    }
    req = urllib.request.Request(SRU + "?" + urllib.parse.urlencode(params), headers=UA)
    # Gallica jette des 500 et coupe des connexions par rafales quand on
    # enchaîne les lieux (constaté run du 2026-07-20 : 29 slugs sur 38 perdus
    # sans retry). On réessaie avec un backoff long — mieux vaut un sync lent
    # qu'un corpus troué.
    derniere: Exception | None = None
    for attente in (0, 10, 30, 90):
        if attente:
            time.sleep(attente)
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return r.read().decode("utf-8", "ignore")
        except Exception as exc:
            derniere = exc
    raise derniere


def search_all(query: str, hard_cap: int = 2000) -> tuple[list[dict], int]:
    rows: list[dict] = []
    start, total = 1, None
    while True:
        xml = sru(query, start)
        if total is None:
            m = NUM_RE.search(xml)
            total = int(m.group(1)) if m else 0
        batch = [
            r for r in records(xml)
        ]
        rows.extend(batch)
        start += len(batch)
        if not batch or start > min(total, hard_cap):
            break
        time.sleep(1.0)
    return rows, total or 0


def _self_test() -> int:
    """Rejoue les trois cas qui mal-appariaient date et fascicule avec
    l'ancienne expression. `python sync_gallica_bmo.py --self-test`."""
    def rec(ident: str, date: str | None, date_avant: bool) -> str:
        d = f"<dc:date>{date}</dc:date>" if date else ""
        i = f"<dc:identifier>{ident}</dc:identifier>"
        return f"<srw:record><dc:title>t</dc:title>{d + i if date_avant else i + d}</srw:record>"
    attendu = [("A1", "1910"), ("A2", "1920"), ("A3", "1930"), ("A4", "1940")]
    cas = {
        "date après identifiant": ("".join(rec(f"A{n}", f"19{n}0", False) for n in range(1, 5)), attendu),
        "date avant identifiant": ("".join(rec(f"A{n}", f"19{n}0", True) for n in range(1, 5)), attendu),
        "enregistrement sans date": ("".join(rec(f"A{n}", None if n == 2 else f"19{n}0", False) for n in range(1, 5)),
                                     [("A1", "1910"), ("A2", ""), ("A3", "1930"), ("A4", "1940")]),
    }
    echecs = 0
    for nom, (xml, voulu) in cas.items():
        obtenu = [(r["gallica_url"], r["issue_date"]) for r in records(xml)]
        ok = obtenu == voulu
        echecs += not ok
        print(f"{'ok ' if ok else 'ÉCHEC'} {nom} : {obtenu}")
    return 1 if echecs else 0


def main() -> int:
    if "--self-test" in sys.argv:
        return _self_test()
    ap = argparse.ArgumentParser()
    # --query répétable : un lieu change de nom, et l'archive emploie le nom de
    # SON époque. Chercher « place de la Nation » dans un bulletin de 1890 ne
    # donne rien : le document dit « place du Trône ». On interroge donc Gallica
    # sous TOUS les noms connus du lieu et on fusionne (dédoublonnage par ark).
    ap.add_argument("--query", action="append")
    ap.add_argument("--slug", default="adhoc")
    ap.add_argument("--only", help="slugs du seed à synchroniser, séparés par des virgules")
    ap.add_argument("--force", action="store_true",
                    help="resynchronise même si le fichier existe (sinon on saute)")
    args = ap.parse_args()

    if args.query:
        targets = {args.slug: args.query}
    else:
        targets = seed_targets()
        if args.only:
            veut = {s.strip() for s in args.only.split(",") if s.strip()}
            inconnus = veut - set(targets)
            if inconnus:
                print(f"ERR slugs absents du seed : {sorted(inconnus)}", file=sys.stderr)
                return 1
            targets = {k: v for k, v in targets.items() if k in veut}
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    synced_at = datetime.now(timezone.utc).isoformat()

    for slug, queries in targets.items():
        if not args.force and not args.query and (OUT_DIR / f"{slug}_bmo.jsonl").exists():
            print(f"{slug}: déjà synchronisé, sauté (--force pour refaire)")
            continue
        if isinstance(queries, str):
            queries = [queries]
        rows, total, vus = [], 0, set()
        echec = None
        for q in queries:
            try:
                r_q, t_q = search_all(q)
            except Exception as exc:
                echec = exc
                continue
            finally:
                time.sleep(3.0)  # souffle entre requêtes — Gallica throttle les rafales
            total += t_q
            for r in r_q:
                cle = r.get("gallica_url") or json.dumps(r, sort_keys=True)
                if cle in vus:
                    continue
                vus.add(cle)
                r["query"] = q            # trace : sous quel nom ce fascicule a été trouvé
                rows.append(r)
        if not rows and echec is not None:
            print(f"ERR {slug}: {type(echec).__name__} {echec}", file=sys.stderr)
            continue
        query = " | ".join(queries)
        out = OUT_DIR / f"{slug}_bmo.jsonl"
        with out.open("w") as f:
            for r in rows:
                r.update({
                    "lieu_slug": slug,
                    "query": r.get("query") or query,
                    "queries": queries,
                    "source": "Gallica / BnF — Bulletin Municipal Officiel de la Ville de Paris (1882–1985)",
                    "source_periodical": f"https://gallica.bnf.fr/ark:/12148/{BMO_ARK.split('_')[0]}/date",
                    "_synced_at": synced_at,
                })
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        print(f"{slug}: {len(rows)}/{total} fascicules -> {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
