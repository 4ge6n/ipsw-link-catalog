"""Unauthenticated Beta/RC IPSW adapter using the public IPSW.dev catalog."""
from __future__ import annotations
from concurrent.futures import ThreadPoolExecutor
import html, json, os, re
from urllib.request import Request, urlopen
from ..normalize import os_key_for

BASE = "https://ipsw.dev"
def get_text(url: str, timeout: int) -> str:
    with urlopen(Request(url, headers={"User-Agent":"ipsw-link-catalog/1.0"}), timeout=timeout) as response: return response.read().decode("utf-8", "replace")
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
    return {"device":identifier,"name":name,"version":re.sub(r'^(?:iOS|iPadOS|tvOS|visionOS|audioOS|macOS)\s+','',label,flags=re.I),"build":build,"url":html.unescape(match.group(1)),"signed":None,"channel":"beta","source":"ipsw.dev"}
def fetch(timeout: int) -> list[dict]:
    configured=os.environ.get("BETA_SOURCE_URL")
    if configured:
        with urlopen(configured, timeout=timeout) as response: return json.load(response)
    jobs=[]
    for build,label in latest_builds(timeout): jobs.extend((build,label,device,name) for device,name in devices_for_build(build, timeout))
    with ThreadPoolExecutor(max_workers=12) as pool: return [row for row in pool.map(lambda item: url_for_device(item, timeout), jobs) if row]
