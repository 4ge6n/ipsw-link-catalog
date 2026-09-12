"""Unauthenticated Beta/RC IPSW adapter using the public IPSW.dev catalog."""
from __future__ import annotations
from concurrent.futures import ThreadPoolExecutor
import html, json, os, re
from urllib.request import Request, urlopen
from ..normalize import os_key_for
from . import ipswbeta

BASE = "https://ipsw.dev"
def get_text(url: str, timeout: int) -> str:
    request=Request(url, headers={"User-Agent":"ipsw-link-catalog/1.0"}); last_error=None
    for _ in range(int(os.environ.get("REQUEST_RETRIES", "3"))):
        try:
            with urlopen(request, timeout=timeout) as response: return response.read().decode("utf-8", "replace")
        except Exception as exc: last_error=exc
    raise last_error
def latest_builds(timeout: int):
    page=get_text(BASE+"/", timeout)
    pattern=r'href="/build/([A-Za-z0-9]+)".*?<h3[^>]*>([^<]+)</h3>'
    return [(build, html.unescape(label).strip()) for build,label in re.findall(pattern, page, re.S) if any(x in label.lower() for x in ("beta", "rc", "seed"))]
def devices_for_build(build: str, timeout: int):
    page=get_text(f"{BASE}/build/{build}", timeout)
    pattern=r'<a class="product[^>]*data-identifier="([^"]+)"[^>]*data-tab="([^"]+)"[^>]*href="/download/[^"/]+/[^"]+".*?<h3[^>]*>([^<]+)</h3>'
    return [(identifier, html.unescape(name).strip()) for identifier,_tab,name in re.findall(pattern, page, re.S) if os_key_for(identifier)]
def url_for_device(item, timeout: int):
    build, label, identifier, name=item
    try: page=get_text(f"{BASE}/download/{identifier}/{build}", timeout)
    except Exception: return None
    match=re.search(r'ipsw-button-down[^>]+href="(https://[^"]+\.ipsw)"', page)
    if not match: return None
    # `label` includes the channel text (for example "iOS 27.0 RC").
    # Keep it as the presentation label, but use a numeric canonical version
    # so the same Apple URL from IPSWBeta.dev is merged rather than duplicated.
    release_label=re.sub(r'^(?:iOS|iPadOS|tvOS|visionOS|audioOS|macOS)\s+','',label,flags=re.I)
    version_match=re.search(r'[0-9]+(?:\.[0-9]+)*', release_label)
    if not version_match: return None
    return {"device":identifier,"name":name,"version":version_match.group(0),"label":release_label,"build":build,"url":html.unescape(match.group(1)),"signed":None,"channel":"beta","source":"ipsw.dev"}
def fetch(timeout: int) -> list[dict]:
    configured=os.environ.get("BETA_SOURCE_URL")
    if configured:
        with urlopen(configured, timeout=timeout) as response: return json.load(response)
    primary=[]
    try:
        jobs=[]
        for build,label in latest_builds(timeout): jobs.extend((build,label,device,name) for device,name in devices_for_build(build, timeout))
        with ThreadPoolExecutor(max_workers=12) as pool: primary=[row for row in pool.map(lambda item: url_for_device(item, timeout), jobs) if row]
    except Exception:
        # The fallback below remains subject to the same Apple-URL validation.
        primary=[]
    supported={"ios", "ipados", "macos", "tvos", "visionos"}
    try:
        # This is a fallback for missing links and also supplements the primary
        # source with each publicly listed beta build, not only the newest RC.
        fallback=ipswbeta.fetch(timeout, supported)
    except Exception:
        fallback=[]
    if not primary and not fallback:
        raise RuntimeError("primary and IPSWBeta.dev beta sources returned no candidates")
    return primary + fallback
