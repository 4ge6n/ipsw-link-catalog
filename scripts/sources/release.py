"""Public, unauthenticated firmware source adapter (ipsw.me API)."""
from __future__ import annotations
import json
from urllib.request import Request, urlopen
from ..normalize import os_key_for

BASE = "https://api.ipsw.me/v4"
def get_json(url: str, timeout: int) -> object:
    request = Request(url, headers={"User-Agent": "ipsw-link-catalog/1.0"})
    with urlopen(request, timeout=timeout) as response: return json.load(response)

def fetch(timeout: int) -> list[dict]:
    devices = get_json(f"{BASE}/devices", timeout)
    candidates: list[dict] = []
    for device in devices:
        identifier = device.get("identifier", "")
        if not os_key_for(identifier): continue
        try: data = get_json(f"{BASE}/device/{identifier}?type=ipsw", timeout)
        except Exception: continue
        for fw in data.get("firmwares", []):
            candidates.append({"device": identifier, "name": data.get("name", identifier), "version": fw.get("version"), "build": fw.get("buildid"), "url": fw.get("url"), "released_at": fw.get("releasedate"), "signed": fw.get("signed"), "source": "ipsw.me"})
    return candidates
