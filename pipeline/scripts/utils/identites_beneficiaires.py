"""Graphie d'un bénéficiaire → identité de l'organisation.

Lit `pipeline/seeds/seed_beneficiaire_identites.csv`, la table versionnée qui
regroupe aussi les fiches bénéficiaires (cf. scripts/enrich/identites_beneficiaires.py).
Les exports de subventions publient chaque exercice sous l'identité
(« ASSOCIATION HALLE ST PIERRE ») : qui compare une graphie jugée ailleurs
(« ASSOCIATION HALLE SAINT PIERRE ») doit comparer les identités. Une graphie
absente de la table est sa propre identité.
"""
from __future__ import annotations

import csv
import re
import unicodedata
from pathlib import Path

SEED = Path(__file__).resolve().parents[2] / "seeds" / "seed_beneficiaire_identites.csv"
_TABLE: dict[str, str] | None = None


def _cle(name: str) -> str:
    return re.sub(r"\s+", " ", str(name or "")).strip().upper()


def _sans_ponctuation(k: str) -> str:
    # Clé du pipeline : apostrophes, points et tirets deviennent des espaces
    # (« MUSEE D'ART » → « MUSEE D ART », « S.A.S. » → « S A S »).
    return re.sub(r"\s+", " ", re.sub(r"[^\w]+", " ", k)).strip()


def _sans_accents(k: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFD", k) if unicodedata.category(c) != "Mn")


def identite_beneficiaire(name: str) -> str:
    global _TABLE
    if _TABLE is None:
        with SEED.open(newline="", encoding="utf-8") as f:
            _TABLE = {_cle(r["beneficiaire_normalise"]): _cle(r["identite"]) for r in csv.DictReader(f)}
    k = _cle(name)
    for essai in (k, _sans_ponctuation(k), _sans_accents(_sans_ponctuation(k))):
        if essai in _TABLE:
            return _TABLE[essai]
    return _sans_accents(_sans_ponctuation(k))
