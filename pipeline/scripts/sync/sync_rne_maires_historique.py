#!/usr/bin/env python3
"""
National ingest — Répertoire national des élus, versions ARCHIVÉES du fichier
des maires → raw_national.rne_maires_historique (BigQuery).

POURQUOI. Le RNE courant (sync_rne_maires.py) est un état : il ne porte que la
date de début de la fonction en cours, remise à zéro à chaque élection. Au
lendemain des municipales de mars 2026 il dit « maire depuis mars 2026 » d'un
maire en poste depuis 2014, et la page de la commune le répète. Ce que le RNE
courant ne sait pas, ses versions précédentes le savent : la Wayback Machine a
archivé le fichier des maires publié sur static.data.gouv.fr (ministère de
l'Intérieur, licence ouverte) à chaque republication. L'état de janvier 2020
porte le mandat 2014, celui d'avril 2021 le mandat 2020, etc. Empilées dans une
seule table (une ligne = un maire × une capture), elles permettent au mart
(mart_maires_national) de remonter la chaîne d'une même personne à la tête de
la même commune : « depuis 2014 au moins, réélu en 2020 et 2026 ».

VIE PRIVÉE (règle du site, 2026-09-09, la même que sync_rne_maires.py) : on ne
charge JAMAIS la date de naissance, le lieu de naissance, le sexe, la catégorie
socioprofessionnelle, la nationalité ni la nuance politique — même dans une
table privée, même dans une archive. Les fichiers archivés contiennent tout
cela ; seules les colonnes KEEP ci-dessous sont lues, le reste est ignoré à la
lecture et n'est jamais réécrit (le fichier source ne vit que dans
pipeline/cache/, hors dépôt).

Colonnes chargées : code_insee (5 caractères), commune, nom, prenom,
date_debut_mandat (ISO), date_debut_fonction (ISO), snapshot_date (date de
publication du fichier par le ministère, lue dans son adresse, ex. 2020-01-14),
source_url (l'adresse archivée exacte, pour citer la provenance).

IDEMPOTENCE. La liste des captures est la constante CAPTURES ; la version de la
table est l'empreinte de cette liste. Relancé sans changement de liste, le
chargeur ne télécharge rien et ne fait rien. Une capture ajoutée change
l'empreinte : la table est reconstruite en entier (_national_raw.replace_snapshot,
protocole `NATIONAL CHANGED` comme les autres chargeurs).

Usage :
    python scripts/sync/sync_rne_maires_historique.py              # charge si la liste a changé
    python scripts/sync/sync_rne_maires_historique.py --dry-run    # dit s'il y a quelque chose à faire
    python scripts/sync/sync_rne_maires_historique.py --force
"""
from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import io
import re
import sys
import time
import unicodedata
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _national_raw as NR  # noqa: E402

TABLE = "rne_maires_historique"
ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = ROOT / "cache" / "wip" / "national" / "rne" / "historique"

# -----------------------------------------------------------------------------
# Les captures. (horodatage Wayback, adresse d'origine sur static.data.gouv.fr)
# Toutes les captures connues :
#   http://web.archive.org/cdx/search/cdx?url=static.data.gouv.fr/resources/repertoire-national-des-elus-1/*&filter=original:.*mai.*&fl=timestamp,original,statuscode&collapse=digest
# On en garde une par année, la plus proche de l'état stable de l'année, du
# plus ancien au plus récent. L'état courant (2026) est chargé à part par
# sync_rne_maires.py. Ajouter une capture = reconstruire la table.
# -----------------------------------------------------------------------------
_BASE = "https://static.data.gouv.fr/resources/repertoire-national-des-elus-1/"
CAPTURES: tuple[tuple[str, str], ...] = (
    # Janvier 2020, AVANT les municipales : porte les mandats 2014. Format
    # « rapport » : 1re ligne « Titre du rapport », tabulé, ISO-8859-1, code
    # commune sur 3 chiffres (+ code département), dates d/m/aaaa sans zéro.
    ("20200629074355", _BASE + "20200114-183638/9-rne-maires.txt"),
    # Avril 2021 : mandats 2020. Tabulé, UTF-8, code commune sur 5 caractères,
    # dates jj/mm/aaaa.
    ("20210429044315", _BASE + "20210422-103627/rne-maires.csv"),
    # Septembre 2022 : même format que 2021.
    ("20220921190304", _BASE + "20220913-182110/rne-maires.csv"),
    # Juin 2023 : en-têtes en snake_case, dates « aaaa-mm-jj 00:00:00+00 ».
    ("20230730100130", _BASE + "20230606-155740/elus-maire.csv"),
    # Juillet 2024 : « ; », codes numériques SANS zéro de tête (« 1001 »).
    ("20240808021231", _BASE + "20240730-125205/elus-maires.csv"),
    # Mars 2025 : « ; », codes sur 5 caractères.
    ("20250317160329", _BASE + "20250312-164715/elus-maires-mai.csv"),
)

# Les seules colonnes lues, par nom d'en-tête normalisé (minuscules, sans
# accents). Tout autre en-tête du fichier est ignoré.
KEEP: dict[str, tuple[str, ...]] = {
    "dep": ("code du departement (maire)", "code du departement", "code_departement"),
    "com": ("code insee de la commune", "code de la commune", "code_commune"),
    "commune": ("libelle de la commune", "libelle_commune"),
    "nom": ("nom de l'elu", "nom_elu"),
    "prenom": ("prenom de l'elu", "prenom_elu"),
    "date_debut_mandat": ("date de debut du mandat", "date_debut_mandat"),
    "date_debut_fonction": ("date de debut de la fonction", "date_debut_fonction"),
}
OUT_COLS = ("code_insee", "commune", "nom", "prenom", "date_debut_mandat", "date_debut_fonction", "snapshot_date", "source_url")
BQ_SCHEMA = ",".join(f"{c}:STRING" for c in OUT_COLS)

# Format « rapport » de 2020 : le département est une lettre outre-mer et la
# commune 3 chiffres ; le code INSEE = préfixe + 3 chiffres (ZA 101 → 97101,
# ZP 735 → 98735). En métropole et Corse, département + 3 chiffres (2A 004).
DEP_OUTRE_MER_2020 = {"ZA": "97", "ZB": "97", "ZC": "97", "ZD": "97", "ZM": "97", "ZS": "97", "ZX": "97",
                      "ZN": "98", "ZP": "98", "ZW": "98"}
CODE_INSEE_RE = re.compile(r"^(\d{5}|2[AB]\d{3})$")
# Un fichier des maires compte ~34 900 lignes ; en dessous, la capture est
# tronquée (la Wayback Machine coupe parfois un transfert) : on retélécharge.
MIN_ROWS = 30_000


def archived_url(ts: str, url: str) -> str:
    """L'adresse Wayback « brute » (id_ : le fichier tel quel, sans bandeau)."""
    return f"https://web.archive.org/web/{ts}id_/{url}"


def snapshot_date_of(url: str) -> str:
    """La date de publication du fichier, lue dans son chemin (20200114-183638 → 2020-01-14)."""
    m = re.search(r"/(\d{4})(\d{2})(\d{2})-\d{6}/", url)
    if not m:
        raise ValueError(f"pas de date de publication dans l'adresse : {url}")
    return f"{m.group(1)}-{m.group(2)}-{m.group(3)}"


def version_of(captures=CAPTURES) -> dict:
    digest = hashlib.sha256("\n".join(archived_url(ts, u) for ts, u in captures).encode()).hexdigest()
    return {"captures_digest": digest[:16], "n_captures": len(captures),
            "oldest": snapshot_date_of(captures[0][1]), "newest": snapshot_date_of(captures[-1][1])}


def _norm_header(h: str) -> str:
    h = unicodedata.normalize("NFD", h.replace("﻿", "")).encode("ascii", "ignore").decode()
    return re.sub(r"\s+", " ", h.strip().lower())


def _decode(raw: bytes) -> str:
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("iso-8859-1")


def iso_date(s: str) -> str:
    """« 5/4/2014 », « 05/04/2014 » ou « 2014-04-05 00:00:00+00 » → « 2014-04-05 » ; vide sinon."""
    s = (s or "").strip()
    if not s:
        return ""
    m = re.fullmatch(r"(\d{1,2})/(\d{1,2})/(\d{4})", s)
    if m:
        return f"{m.group(3)}-{int(m.group(2)):02d}-{int(m.group(1)):02d}"
    m = re.match(r"(\d{4}-\d{2}-\d{2})", s)
    if m:
        return m.group(1)
    raise ValueError(f"date illisible : {s!r}")


def code_insee(dep: str, com: str) -> str | None:
    dep, com = (dep or "").strip().upper(), (com or "").strip().upper()
    if not com:
        return None
    if len(com) == 3 and com.isdigit() and dep:
        code = DEP_OUTRE_MER_2020.get(dep, dep) + com          # format « rapport » 2020
    elif com.isdigit():
        code = com.zfill(5)                                    # 2024 : « 1001 » → « 01001 »
    else:
        code = com
    return code if CODE_INSEE_RE.match(code) else None


def parse_capture(text: str, ts: str, url: str) -> tuple[list[list[str]], dict]:
    """Les lignes de sortie d'une capture + un petit bilan (lignes lues, rejetées)."""
    lines = text.splitlines()
    if lines and lines[0].strip().lower().startswith("titre du rapport"):
        lines = lines[1:]
    delim = "\t" if "\t" in lines[0] else ";"
    reader = csv.reader(io.StringIO("\n".join(lines)), delimiter=delim)
    header = [_norm_header(h) for h in next(reader)]
    idx: dict[str, int | None] = {}
    for key, names in KEEP.items():
        found = [i for i, h in enumerate(header) if h in names]
        idx[key] = found[0] if found else None
    missing = [k for k in ("com", "commune", "nom", "prenom", "date_debut_fonction") if idx[k] is None]
    if missing:
        raise SystemExit(f"colonnes attendues absentes dans {url} : {missing} — en-tête : {header}")
    snapshot, source = snapshot_date_of(url), archived_url(ts, url)
    cell = lambda row, key: (row[idx[key]] if idx[key] is not None and idx[key] < len(row) else "").strip()  # noqa: E731
    out, bilan = [], {"lues": 0, "sans_code": 0}
    for row in reader:
        if not any(row):
            continue
        bilan["lues"] += 1
        code = code_insee(cell(row, "dep"), cell(row, "com"))
        if code is None:
            bilan["sans_code"] += 1
            continue
        out.append([code, cell(row, "commune"), cell(row, "nom"), cell(row, "prenom"),
                    iso_date(cell(row, "date_debut_mandat")), iso_date(cell(row, "date_debut_fonction")),
                    snapshot, source])
    return out, bilan


def fetch(ts: str, url: str) -> str:
    """Télécharge (cache local) ; retente quand la Wayback Machine a coupé le transfert."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cached = CACHE_DIR / f"{ts}_{Path(url).name}"
    for attempt in range(1, 4):
        if not cached.exists():
            req = urllib.request.Request(archived_url(ts, url), headers={"User-Agent": "qipu-pipeline/1.0"})
            with urllib.request.urlopen(req, timeout=600) as r:
                cached.write_bytes(r.read())
        text = _decode(cached.read_bytes())
        if text.count("\n") >= MIN_ROWS:
            return text
        print(f"  ! capture {ts} tronquée ({text.count(chr(10)):,} lignes), nouvel essai {attempt}/3")
        cached.unlink()
        time.sleep(5 * attempt)
    raise SystemExit(f"capture {ts} toujours tronquée après 3 essais : {archived_url(ts, url)}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    version = version_of()
    if NR.is_version_current(TABLE, version) and not args.force:
        print(f"  = {TABLE} : {version['n_captures']} captures ({version['oldest']} → {version['newest']}) déjà chargées — rien à faire")
        return 0
    print(f"→ RNE archivé → {NR.DATASET_ID}.{TABLE} — {version['n_captures']} captures ({version['oldest']} → {version['newest']})")
    if args.dry_run or NR.CHECK_ONLY:
        if NR.CHECK_ONLY:
            NR.would_change(TABLE, f"{version['n_captures']} captures")
        return 0
    out = CACHE_DIR / f"{TABLE}.csv"
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    total = 0
    with open(out, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(OUT_COLS)
        for ts, url in CAPTURES:
            rows, bilan = parse_capture(fetch(ts, url), ts, url)
            if len(rows) < MIN_ROWS:
                raise SystemExit(f"capture {ts} : {len(rows):,} maires seulement après lecture — format inattendu ?")
            w.writerows(rows)
            total += len(rows)
            print(f"  {snapshot_date_of(url)} : {len(rows):>6,} maires ({bilan['sans_code']} lignes sans code INSEE) ← {Path(url).name}")
    print(f"  {total:,} lignes, {len(OUT_COLS)} colonnes (aucune donnée sensible) → {out.name}")
    NR.replace_snapshot(TABLE, out, BQ_SCHEMA, version=version,
                        load_args=("--source_format=CSV", "--skip_leading_rows=1", "--allow_quoted_newlines"), force=args.force)
    return 0


if __name__ == "__main__":
    sys.exit(main())
