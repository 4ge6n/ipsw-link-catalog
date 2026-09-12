"""Public IPSWBeta.dev fallback for current beta/RC Apple CDN links.

This source is used only for OS families not returned by the primary beta
catalog.  It never publishes an IPSWBeta.dev URL: candidates are accepted
later only when their extracted download URL is an allowed Apple CDN HTTPS
IPSW.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import html
import re
from urllib.parse import unquote
from urllib.request import Request, urlopen

BASE = "https://ipswbeta.dev"
PATHS = {"ios": "ios", "ipados": "ipados", "macos": "macos", "tvos": "tvos", "visionos": "visionos"}
APPLE_URL = re.compile(r'data-url="(https://(?:updates\.cdn-apple\.com|secure-appldnld\.apple\.com|appldnld\.apple\.com)/[^"?#]+\.ipsw)"')
FILENAME = re.compile(r'_([0-9]+(?:\.[0-9]+)*)_([0-9]+[A-Za-z][A-Za-z0-9]*)_Restore\.ipsw$')

def get_text(url: str, timeout: int) -> str:
    request = Request(url, headers={"User-Agent": "ipsw-link-catalog/1.0"})
    with urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", "replace")

def current_tracks(timeout: int) -> dict[str, str]:
    page = get_text(BASE + "/", timeout)
    found = re.findall(r'href="/(ios|ipados|macos|tvos|visionos)/([0-9]+\.x)/"', page)
    return {key: track for key, track in found}

def devices_for_track(os_key: str, track: str, timeout: int) -> list[str]:
    path = PATHS[os_key]
    page = get_text(f"{BASE}/{path}/{track}/", timeout)
    pattern = rf'href="/{re.escape(path)}/{re.escape(track)}/([^"/?#]+)"'
    return sorted({unquote(identifier) for identifier in re.findall(pattern, page) if re.fullmatch(r"[A-Za-z]+[0-9]+,[0-9]+", unquote(identifier))})

def candidates_for_device(item: tuple[str, str, str], timeout: int) -> list[dict]:
    os_key, track, identifier = item
    try:
        page = get_text(f"{BASE}/{PATHS[os_key]}/{track}/{identifier}", timeout)
    except Exception:
        return []
    title = re.search(r"<title>\s*([^<–]+?)\s*[–-]", page, re.S)
    name = html.unescape(title.group(1)).strip() if title else identifier
    candidates=[]
    for match in APPLE_URL.finditer(page):
        url = html.unescape(match.group(1))
        parsed = FILENAME.search(url)
        if not parsed:
            continue
        version, build = parsed.groups()
        preceding=page[:match.start()]
        labels=re.findall(r'<div class="font-bold">\s*([^<]+)', preceding)
        label=html.unescape(labels[-1]).strip() if labels else f"{version} beta"
        candidates.append({"device": identifier, "name": name, "version": version, "label": label, "build": build, "url": url, "signed": None, "channel": "beta", "source": "ipswbeta.dev"})
    return candidates

def fetch(timeout: int, os_keys: set[str]) -> list[dict]:
    tracks = current_tracks(timeout)
    jobs = []
    for os_key in sorted(os_keys):
        track = tracks.get(os_key)
        if track:
            jobs.extend((os_key, track, device) for device in devices_for_track(os_key, track, timeout))
    with ThreadPoolExecutor(max_workers=12) as pool:
        rows=pool.map(lambda item: candidates_for_device(item, timeout), jobs)
        return [candidate for device_rows in rows for candidate in device_rows]
