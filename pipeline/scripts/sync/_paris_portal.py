"""
The City of Paris open data portal, and where to reach it (2026-09-23).

opendata.paris.fr is the City's name for an Opendatasoft portal whose own
address is parisdata.opendatasoft.com: the same API, the same datasets (490 on
23/09/2026, record counts identical). That day the City's name stopped
resolving (NXDOMAIN, at 1.1.1.1 and 8.8.8.8 too) while the portal answered at
its own address, and every Paris sync would have failed on Monday.

A refresh must not hang on one DNS record: the City's name first — it would
follow the City to another platform —, the portal's own address when the name
does not resolve. Only the API calls move; the links the site shows readers
keep the City's name.
"""
from __future__ import annotations

import socket
from functools import lru_cache

CITY_HOST = "opendata.paris.fr"
PLATFORM_HOST = "parisdata.opendatasoft.com"


@lru_cache(maxsize=1)
def host() -> str:
    try:
        socket.getaddrinfo(CITY_HOST, 443)
        return CITY_HOST
    except socket.gaierror:
        print(f"  ! {CITY_HOST} ne résout pas : le portail est lu à son adresse Opendatasoft, {PLATFORM_HOST}")
        return PLATFORM_HOST


def api(path: str = "") -> str:
    """« https://<host>/api/explore/v2.1<path> »."""
    return f"https://{host()}/api/explore/v2.1{path}"
