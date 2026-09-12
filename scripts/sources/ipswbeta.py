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

def candidate_for_device(item: tuple[str, str, str], timeout: int) -> dict | None:
    os_key, track, identifier = item
    try:
        page = get_text(f"{BASE}/{PATHS[os_key]}/{track}/{identifier}", timeout)
    except Exception:
        return None
    match = APPLE_URL.search(page)
    if not match:
        return None
    url = html.unescape(match.group(1))
    parsed = FILENAME.search(url)
    if not parsed:
        return None
    version, build = parsed.groups()
    title = re.search(r"<title>\s*([^<–]+?)\s*[–-]", page, re.S)
    name = html.unescape(title.group(1)).strip() if title else identifier
    # The first data-url is the page's current RC/beta row.  Its label is
    # present in the page's Latest field and preserves RC/beta classification.
    label_match = re.search(r"Latest:.*?font-semibold\">\s*([^<]+)", page, re.S)
    label = html.unescape(label_match.group(1)).strip() if label_match else f"{version} beta"
    return {"device": identifier, "name": name, "version": version, "label": label, "build": build, "url": url, "signed": None, "channel": "beta", "source": "ipswbeta.dev"}

def fetch(timeout: int, os_keys: set[str]) -> list[dict]:
    tracks = current_tracks(timeout)
    jobs = []
    for os_key in sorted(os_keys):
        track = tracks.get(os_key)
        if track:
            jobs.extend((os_key, track, device) for device in devices_for_track(os_key, track, timeout))
    with ThreadPoolExecutor(max_workers=12) as pool:
        return [row for row in pool.map(lambda item: candidate_for_device(item, timeout), jobs) if row]
