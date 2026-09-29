#!/usr/bin/env python3
"""
Qui reçoit l'argent de la commune — agrégation des jeux « subventions » au
schéma national SCDL publiés sur data.gouv.

Pourquoi ce script existe :
    La liste nominative des subventions n'existe dans aucun jeu NATIONAL
    (vérifié le 2026-09-10 sur data.economie, OFGL et Data.Subvention, dont
    l'API est en outre soumise à habilitation). Elle existe en revanche
    commune par commune, au schéma SCDL `subventions`, pour quelques dizaines
    de communes. Une seule correspondance de colonnes suffit : le schéma est
    respecté (nomBeneficiaire, idBeneficiaire, rnaBeneficiaire, objet, montant…).

    Le reste des communes ne publie ces listes que dans l'annexe de sa maquette
    budgétaire (M14 B1.7 / M57 B8) — c'est l'objet de pipeline/scripts/m57/.

Règle de publication — identification POSITIVE :
    On ne publie que ce qu'on reconnaît comme un organisme, soit par un
    identifiant (SIRET ou numéro RNA), soit par un mot d'organisation dans le
    nom (association, club, comité, école, crèche, fédération…). Tout le reste
    est écarté et compté.

    Pourquoi pas seulement l'identifiant : beaucoup de communes laissent la
    colonne SIRET vide alors que le bénéficiaire est clairement une association
    (« ASS CULTURELLE ECOLE PRIM BERLIOZ ») — s'en tenir à l'identifiant jetait
    1 976 lignes sur 6 359 à Lyon. Pourquoi pas seulement le nom : les fichiers
    contiennent de vraies personnes physiques (« DIDIERLAURENT JEAN FRANCOIS »).
    La colonne `nature` du schéma ne dit que « aide en numéraire / en nature »,
    elle ne distingue pas les personnes.

    En cas de doute on exclut : mieux vaut un total incomplet qu'un nom de
    particulier publié.

Sortie : website/src/data/communes-subventions.json
"""
from __future__ import annotations
import csv, io, json, re, sys, unicodedata, urllib.parse, urllib.request
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).parent.parent.parent.parent
OUT = ROOT / "website" / "src" / "data" / "communes-subventions.json"
UA = {"User-Agent": "qipu-pipeline (contact: qipu.org)"}
API = "https://www.data.gouv.fr/api/1/"
# Mots qui identifient un ORGANISME sans ambiguïté. Rien de générique
# (« maison », « centre » seuls sont trop courants dans les patronymes).
ORGANISME = re.compile(
    r"\b(ass(oc(iation)?)?|asl|amicale|club|comit[ée]|f[ée]d[ée]ration|union|ligue|collectif|"
    r"soci[ée]t[ée]|fondation|institut|conservatoire|orchestre|compagnie|cie|troupe|ensemble|"
    r"[ée]cole|coll[èe]ge|lyc[ée]e|cr[èe]che|halte|centre social|maison de|maison des|mjc|foyer|"
    r"th[ée][âa]tre|mus[ée]e|cin[ée]ma|biblioth[èe]que|m[ée]diath[èe]que|"
    r"ccas|cias|caisse des [ée]coles|ogec|apel|fcpe|pep\b|secours|croix.rouge|restos|banque alimentaire|"
    r"sport|sportif|sportive|omnisports|gymnique|athl[ée]tique|olympique|racing|stade|"
    r"\bfc\b|\bus\b|\bas\b|\bsa\b|\bsarl\b|\bsas\b|\bsci\b|\bscic\b|\bscop\b|\bgip\b|\bepic\b|"
    r"syndicat|mutuelle|coop[ée]rative|entreprise|groupe|r[ée]gie|office|agence|chambre|"
    r"paroisse|temple|synagogue|mosqu[ée]e|dioc[èe]se|anciens combattants|jumelage)\b", re.I)
PAS_COMMUNE = re.compile(r"m[ée]tropole|agglom|communaut[ée]|d[ée]partement|r[ée]gion|universit|syndicat|chu\b|gip\b", re.I)

def flat(s: str) -> str:
    s = unicodedata.normalize("NFD", (s or "").lower()).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()

def get(url: str, limit: int = 40_000_000) -> bytes:
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120) as r:
        return r.read(limit)

def communes_index() -> dict:
    data = json.loads(get("https://geo.api.gouv.fr/communes?fields=nom,code,population&format=json"))
    idx = {}
    for c in data:
        idx.setdefault(flat(c["nom"]), c)
    return idx

def colonne(cols: list[str], *motifs: str) -> str | None:
    """Le schéma est respecté mais l'orthographe varie (« nomBeneficiere »,
    « Montant ») : on retrouve la colonne par motif, insensible à la casse."""
    for m in motifs:
        for c in cols:
            if re.fullmatch(m, c.strip().lstrip("﻿"), re.I):
                return c
    return None

def montant(v: str) -> float | None:
    if v is None:
        return None
    t = re.sub(r"[^\d,.\-]", "", str(v)).replace(" ", "")
    if not t:
        return None
    if "," in t and "." in t:
        t = t.replace(".", "").replace(",", ".")
    else:
        t = t.replace(",", ".")
    try:
        return float(t)
    except ValueError:
        return None

def lire_csv(raw: bytes) -> list[dict]:
    txt = raw.decode("utf-8", "replace")
    if txt.lstrip().startswith("<"):          # page HTML servie à la place du CSV
        return []
    first = txt.split("\n", 1)[0]
    sep = max([",", ";", "\t"], key=first.count)
    return list(csv.DictReader(io.StringIO(txt), delimiter=sep))

def main() -> int:
    idx = communes_index()
    jeux = {}
    for q in ["datasets/?schema=scdl%2Fsubventions&page_size=100",
              "datasets/?q=" + urllib.parse.quote("données essentielles conventions subventions") + "&page_size=100"]:
        try:
            for x in json.loads(get(API + q)).get("data", []):
                jeux[x["id"]] = x
        except Exception as e:
            print(f"  ⚠ {q[:40]} : {e}")
    print(f"  {len(jeux)} jeux candidats")

    par_commune: dict[str, dict] = {}
    for x in jeux.values():
        org = (x.get("organization") or {}).get("name") or ""
        if PAS_COMMUNE.search(org):
            continue
        cle = flat(re.sub(r"^(ville|commune|mairie|municipalite)\s+(de\s+|du\s+|des\s+|d\s*)?", "", flat(org)))
        commune = idx.get(cle)
        if not commune:
            continue
        for res in x.get("resources") or []:
            if (res.get("format") or "").lower() != "csv":
                continue
            try:
                rows = lire_csv(get(res["url"]))
            except Exception:
                continue
            if not rows:
                continue
            cols = list(rows[0].keys())
            c_ben = colonne(cols, r"nomB[ée]n[ée]ficiai?re?", r"b[ée]n[ée]ficiaire", r"nom_beneficiaire")
            c_mnt = colonne(cols, r"montant", r"montant_?vote", r"montantVote")
            c_obj = colonne(cols, r"objet", r"objet_?dossier")
            c_sir = colonne(cols, r"idB[ée]n[ée]ficiaire", r"siret", r"siren")
            c_rna = colonne(cols, r"rnaB[ée]n[ée]ficiaire", r"rna")
            c_an  = colonne(cols, r"dateConvention", r"annee", r"exercice")
            if not (c_ben and c_mnt):
                continue
            b = par_commune.setdefault(commune["code"], {
                "nom": commune["nom"], "pop": commune["population"],
                "par_annee": defaultdict(lambda: defaultdict(float)), "objets": {}, "annees": set(),
                "jeux": set(), "exclus": 0,
            })
            b["jeux"].add(x.get("title", "")[:80])
            for r in rows:
                nom = (r.get(c_ben) or "").strip()
                v = montant(r.get(c_mnt))
                if not nom or v is None or v <= 0:
                    continue
                # publication réservée aux ORGANISMES : un bénéficiaire sans
                # identifiant SIRET ni RNA peut être une personne physique.
                ident = (r.get(c_sir) or "") if c_sir else ""
                rna = (r.get(c_rna) or "") if c_rna else ""
                identifie = bool(re.search(r"\d{9}", ident)) or bool(re.search(r"W\d{9}", rna, re.I))
                if not (identifie or ORGANISME.search(nom)):
                    b["exclus"] += 1
                    continue
                an = None
                if c_an and r.get(c_an):
                    m = re.search(r"(20\d\d)", str(r[c_an]))
                    an = int(m.group(1)) if m else None
                b["par_annee"][an][nom[:90]] += v
                if c_obj and r.get(c_obj) and nom[:90] not in b["objets"]:
                    b["objets"][nom[:90]] = re.sub(r"\s+", " ", r[c_obj])[:90]
                if c_an and r.get(c_an):
                    m = re.search(r"(20\d\d)", str(r[c_an]))
                    if m:
                        b["annees"].add(int(m.group(1)))

    out = {"source": "Jeux « subventions » au schéma SCDL, agrégés depuis data.gouv.fr",
           "source_url": "https://www.data.gouv.fr/datasets?schema=scdl%2Fsubventions",
           "generated_at": datetime.now(timezone.utc).isoformat(),
           "regle": "Seuls les bénéficiaires identifiés par un SIRET ou un numéro RNA sont publiés ; les personnes physiques sont exclues.",
           "communes": {}}
    for insee, b in par_commune.items():
        # Les fichiers couvrent plusieurs exercices : additionner toutes les
        # lignes cumulait les années (Vaulx-en-Velin sortait à 49 M€ pour un
        # compte 65748 de 5 M€). On publie le DERNIER exercice renseigné.
        annees = sorted([a for a in b["par_annee"] if a], reverse=True)
        an = annees[0] if annees else None
        tri = sorted(b["par_annee"][an].items(), key=lambda kv: -kv[1]) if an else []
        if not tri:
            continue
        out["communes"][insee] = {
            "nom": b["nom"],
            "total": round(sum(v for _, v in tri), 2),
            "n_beneficiaires": len(tri),
            "annee": an,
            "annees_disponibles": annees[:6],
            "exclus_personnes_physiques": b["exclus"],
            "top": [{"nom": n, "montant": round(v, 2), "objet": b["objets"].get(n, "")} for n, v in tri[:12]],
        }
    out["n_communes"] = len(out["communes"])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    print(f"  ✓ {out['n_communes']} communes, {OUT.stat().st_size/1024:.0f} Ko → {OUT.relative_to(ROOT)}")
    for insee, c in sorted(out["communes"].items(), key=lambda kv: -kv[1]["total"])[:8]:
        print(f"     {c['nom'][:24]:24s} {c['n_beneficiaires']:5d} organismes  {c['total']:>14,.0f} €"
              f"   (exclus : {out['communes'][insee]['exclus_personnes_physiques']})")
    return 0

if __name__ == "__main__":
    sys.exit(main())

# ─────────────────────────────────────────────────────────────────────────────
# ÉTAT AU 2026-09-10 : LA SORTIE N'EST PAS PUBLIABLE EN L'ÉTAT.
#
# 11 communes seulement, et le contrôle contre le compte 65748 de la balance
# DGFiP donne des écarts de −96 % à +58 % :
#     Lyon 2023 −63 %, Vaulx-en-Velin 2025 +58 %, Quimper 2025 −28 %,
#     Rillieux-la-Pape 2024 −45 %, Charleville-Mézières 2024 −37 %,
#     Antibes 2026 −96 % (l'exercice vient de commencer, 2 lignes).
#
# Trois causes, toutes structurelles et aucune corrigeable par le code :
#   1. chaque commune publie une année différente (2018 → 2026), alors que la
#      balance de référence est annuelle ;
#   2. certains fichiers ne listent que les subventions au-dessus d'un seuil
#      (l'obligation légale porte sur les conventions > 23 000 €) ;
#   3. le périmètre varie : certaines incluent le CCAS et les aides en nature,
#      d'autres non.
#
# Ce qu'il faudrait pour publier : n'afficher une commune que si son exercice
# correspond à celui de la balance ET que l'écart tient dans ±20 %. Sur les
# 11 communes actuelles il en resterait deux ou trois — pas de quoi faire une
# section. La couverture viendra plutôt de l'extraction des annexes des
# maquettes (pipeline/scripts/m57/), qui porte l'exercice du document lu.
# ─────────────────────────────────────────────────────────────────────────────
