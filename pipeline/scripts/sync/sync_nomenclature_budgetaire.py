#!/usr/bin/env python3
"""
Nomenclatures budgétaires officielles → table de libellés par code.

Pourquoi ce script existe :
    La balance DGFiP « présentation croisée nature-fonction » ne porte QUE des
    codes : FONCTION="212", COMPTE="6411". Sans table de correspondance on ne
    peut afficher qu'un code, et on ne peut surtout pas en inventer le sens.
    La DGCL publie ses nomenclatures en CSV, en domaine public : on les ingère.

Source :
    data.gouv.fr — « Instruction budgétaire et comptable M57, M52 et M14
    +500 hab au 1er janvier 2022 — Plan des Comptes développé »
    Licence ouverte / domaine public (Other-PD).

⚠ PIÈGE CENTRAL — les deux fichiers ne parlent pas de la même chose.
    `m57d-v2.csv` a une colonne TYPE qui vaut « nature » ou « fonction » : il
    porte À LA FOIS le plan de comptes M57 et la nomenclature FONCTIONNELLE
    M57 (0 Services généraux, 01 Opérations non ventilables, 211 Écoles
    maternelles, 212 Écoles primaires…).
    `m14.csv` ne porte QUE le plan de comptes M14, par nature. Son code "212"
    signifie « Agencements et aménagements de terrains », pas « Écoles
    primaires ». Chercher un code de FONCTION dans la table M14 produit un
    libellé faux et plausible — exactement le genre d'erreur qui passe la
    relecture. Les deux axes sont donc émis dans des dictionnaires séparés, et
    il n'existe volontairement PAS de table `fonction_m14` : la nomenclature
    fonctionnelle M14 n'est pas dans ce jeu de données, et on ne devine pas.

Sortie :
    pipeline/data/nomenclature-budgetaire.json
        {
          "fonction_m57": {"212": "Ecoles primaires", ...},
          "nature_m57":   {"6411": "Personnel titulaire", ...},
          "nature_m14":   {"6411": "Personnel titulaire", ...}
        }
    Référence côté pipeline uniquement : les libellés sont recopiés dans les
    fichiers par commune, pour qu'aucune table de 5 000 entrées ne parte dans
    le navigateur.

Idempotent : oui (re-télécharge seulement si absent ou --force).
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[3]
CACHE_DIR = ROOT / "pipeline" / "cache" / "nomenclature"
OUTPUT_FILE = ROOT / "pipeline" / "data" / "nomenclature-budgetaire.json"

DATASET_PAGE = (
    "https://www.data.gouv.fr/datasets/instruction-budgetaire-et-comptable-"
    "m57-m52-et-m14-500hab-au-1er-janvier-2022-plan-des-comptes-developpe-"
    "maj-06-02-2023"
)
BASE = "https://static.data.gouv.fr/resources"
RESOURCES = {
    # M57 développée : porte les deux axes (TYPE = nature | fonction).
    "m57d-v2.csv": (
        f"{BASE}/instruction-budgetaire-et-comptable-m57-m52-et-m14-500hab-"
        f"au-1er-janvier-2022-plan-des-comptes-developpe/20230206-114847/m57d-v2.csv"
    ),
    # M14 : plan de comptes par NATURE seulement.
    "m14.csv": (
        f"{BASE}/instruction-budgetaire-et-comptable-m57-au-1er-janvier-2022-"
        f"plan-des-comptes-developpe/20220510-142455/m14.csv"
    ),
}


def download(force: bool = False) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    for name, url in RESOURCES.items():
        dest = CACHE_DIR / name
        if dest.exists() and not force:
            print(f"  = {name} déjà en cache ({dest.stat().st_size:,} octets)")
            continue
        print(f"  ↓ {name}")
        req = Request(url, headers={"User-Agent": "qipu-pipeline/1.0"})
        with urlopen(req, timeout=120) as resp:
            dest.write_bytes(resp.read())
        print(f"    {dest.stat().st_size:,} octets")


def normalise_apostrophes(s: str) -> str:
    """Une seule apostrophe, la typographique.

    Le CSV DGCL est en Windows-1252 : lu en latin-1, son apostrophe courbe
    devient U+0092, un caractère de contrôle invisible qui casse toute
    comparaison de chaîne. On lit donc en cp1252 — et on répare quand même
    U+0092 ici, au cas où une autre source arriverait mal décodée.

    La source contient aussi des apostrophes doublées, séquelles d'un
    échappement SQL : « Charges d’'intervention », « Droits d''utilisation ».
    On les réduit à une.
    """
    s = s.replace("\x92", "’").replace("\u2019", "’").replace("'", "’")
    return re.sub(r"’{2,}", "’", s)


def clean(label: str) -> str:
    """Libellé de nomenclature → texte affichable.

    Les fichiers DGCL crient les niveaux hauts (« CHARGES DE PERSONNEL ») et
    numérotent parfois les classes (« COMPTES DE TIERS 1 »). On retire le
    numéro de classe traînant et on remet en casse de phrase ce qui est tout
    en capitales, sans toucher aux libellés déjà correctement casés.
    """
    s = normalise_apostrophes(" ".join(label.split()))
    if s and s[-1].isdigit() and s[:-1].rstrip().isupper():
        s = s[:-1].rstrip()
    letters = [c for c in s if c.isalpha()]
    if letters and all(c.isupper() for c in letters) and " " in s:
        # Une PHRASE en capitales se remet en casse de phrase. Un token seul,
        # non : « CCAS », « APA », « RSA », « U.R.S.S.A.F. » sont des sigles, et
        # « Ccas » n'existe pas. La présence d'une espace sépare les deux cas.
        s = s.capitalize()
    return s


def build() -> dict[str, dict[str, str]]:
    out: dict[str, dict[str, str]] = {"fonction_m57": {}, "nature_m57": {}, "nature_m14": {}}

    # M57 : un seul fichier, deux axes, distingués par la colonne TYPE.
    with (CACHE_DIR / "m57d-v2.csv").open(encoding="cp1252", newline="") as f:
        for row in csv.DictReader(f, delimiter=";"):
            code = (row.get("CODE") or "").strip()
            lib = clean(row.get("LIBELLE") or "")
            if not code or not lib:
                continue
            axe = (row.get("TYPE") or "").strip()
            if axe == "fonction":
                # Les codes « chapitres » du vote par fonction (930, 934212…)
                # sont la même référence préfixée : on stocke la référence nue,
                # le préfixe est retiré à la lecture de la balance.
                out["fonction_m57"].setdefault(code, lib)
            elif axe == "nature":
                out["nature_m57"].setdefault(code, lib)

    # M14 : plan de comptes par nature UNIQUEMENT. Aucune fonction ici.
    with (CACHE_DIR / "m14.csv").open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f, delimiter=";"):
            code = (row.get("m14_id") or "").strip()
            lib = clean(row.get("m14_lib") or "")
            if code and lib:
                out["nature_m14"].setdefault(code, lib)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--force", action="store_true", help="re-télécharger les CSV")
    args = ap.parse_args()

    print("Nomenclatures budgétaires DGCL")
    download(force=args.force)
    tables = build()

    for k, v in tables.items():
        print(f"  {k:<14} {len(v):>5} codes")

    # Garde-fou : le piège que ce script existe pour éviter. Si « 212 » porte le
    # même libellé des deux côtés, c'est qu'on a mélangé les axes.
    f212 = tables["fonction_m57"].get("212")
    n212 = tables["nature_m14"].get("212")
    if f212 and n212 and f212 == n212:
        print("✗ fonction et nature partagent un libellé sur 212 : axes mélangés", file=sys.stderr)
        return 1
    print(f"  contrôle : fonction 212 = {f212!r} · nature M14 212 = {n212!r}")

    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_FILE.write_text(
        json.dumps(
            {
                "source": "DGCL — instructions budgétaires et comptables M57 et M14, plan de comptes développé",
                "source_url": DATASET_PAGE,
                "licence": "Domaine public (Other-PD)",
                **tables,
            },
            ensure_ascii=False,
            indent=1,
        ),
        encoding="utf-8",
    )
    print(f"→ {OUTPUT_FILE.relative_to(ROOT)} ({OUTPUT_FILE.stat().st_size:,} octets)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
