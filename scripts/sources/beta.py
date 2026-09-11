"""Optional public beta feed adapter.

Set BETA_SOURCE_URL to a JSON array using the normalized candidate fields.  This
keeps authenticated Apple Developer pages out of CI and makes alternate public
sources reviewable instead of hard-coded.
"""
from __future__ import annotations
import json, os
from urllib.request import urlopen

def fetch(timeout: int) -> list[dict]:
    url = os.environ.get("BETA_SOURCE_URL")
    if not url: return []
    with urlopen(url, timeout=timeout) as response:
        data = json.load(response)
    if not isinstance(data, list): raise ValueError("BETA_SOURCE_URL must return a JSON array")
    return [{**row, "source": row.get("source", "beta-feed")} for row in data]
