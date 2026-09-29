#!/usr/bin/env python3
"""
Recharge UNE année des balances DGFiP dans raw_national.dgfip_balances sans
toucher aux autres.

Depuis le 2026-09-14, c'est exactement ce que fait
`sync_dgfip_balances_national.py --years <année>` (table temporaire, compte
exact contre le serveur, garde de volume, transaction) : ce script n'en est
plus qu'un raccourci, gardé pour les commandes déjà notées ailleurs.

Usage :
    python scripts/sync/reload_dgfip_year.py 2023 [--force]
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sync_dgfip_balances_national import expected_count, sync_year  # noqa: E402


def main() -> int:
    year = int(sys.argv[1])
    sync_year(year, expected_count(year), force="--force" in sys.argv[2:])
    return 0


if __name__ == "__main__":
    sys.exit(main())
