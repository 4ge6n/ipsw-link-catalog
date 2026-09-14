"""Apple's own restore-image catalog, the one Finder and iTunes download from.

Apple publishes the currently restorable build for every device here, so an
entry is authoritative both for the download URL and for the fact that the
build is being signed right now. The catalog says nothing about builds it has
dropped, which is why signing for those is probed separately.
"""
from __future__ import annotations
import html
import os
import plistlib
import re
from datetime import timezone
from email.utils import parsedate_to_datetime
from urllib.request import Request, urlopen
from ..normalize import os_key_for

CATALOG = ("https://itunes.apple.com/WebObjects/MZStore.woa/wa"
           "/com.apple.jingle.appserver.client.MZITunesClientCheck/version")
# Apple's own announcements, which carry the time each build shipped.
RELEASES = "https://developer.apple.com/news/releases/rss/releases.rss"
# "iOS 27.0 (24A437)", or "iOS 27.0 RC (24A435)" before release day.
TITLE = re.compile(r"(.+?)\s+([0-9][0-9.]*)(?:\s+(RC|beta[^()]*|Release Candidate[^()]*))?\s+\(([A-Za-z0-9]+)\)")
# Device identifiers look like iPhone18,5 or AppleTV5,3. Container keys such as
# "iPodSoftwareVersions" must not be mistaken for one.
IDENTIFIER = re.compile(r"^[A-Za-z][A-Za-z0-9]*[0-9]+,[0-9]+$")

def get_plist(url: str, timeout: int) -> dict:
    request = Request(url, headers={"User-Agent": "ipsw-link-catalog/1.0"})
    last_error = None
    for _ in range(int(os.environ.get("REQUEST_RETRIES", "3"))):
        try:
            with urlopen(request, timeout=timeout) as response:
                return plistlib.loads(response.read())
        except Exception as exc:
            last_error = exc
    raise last_error

def release_dates(timeout: int) -> dict[tuple[str, str], str]:
    """When Apple announced each build, taken from its own releases feed.

    Apple's restore catalog carries no dates at all. The developer releases
    feed does, to the minute, and covers the builds that have just shipped,
    which are exactly the ones the catalog has yet to date.
    """
    request = Request(RELEASES, headers={"User-Agent": "ipsw-link-catalog/1.0"})
    with urlopen(request, timeout=timeout) as response:
        feed = response.read().decode("utf-8", "replace")
    dates: dict[tuple[str, str], str] = {}
    for item in re.findall(r"<item>(.*?)</item>", feed, re.S):
        title = re.search(r"<title>(.*?)</title>", item, re.S)
        posted = re.search(r"<pubDate>(.*?)</pubDate>", item, re.S)
        if not (title and posted): continue
        named = TITLE.fullmatch(html.unescape(title.group(1)).strip())
        if not named: continue
        _, version, prerelease, build = named.groups()
        try:
            moment = parsedate_to_datetime(posted.group(1).strip()).astimezone(timezone.utc)
        except (TypeError, ValueError):
            continue
        key = (version, build)
        stamp = moment.isoformat().replace("+00:00", "Z")
        # A build often appears first as an RC and again on release day; the
        # release is what a release record is dated by.
        if prerelease and key in dates: continue
        if not prerelease or key not in dates: dates[key] = stamp
    return dates

def restore_entries(node, device: str | None = None):
    """Walk to every Restore dict, remembering the device identifier above it."""
    if isinstance(node, dict):
        if isinstance(node.get("FirmwareURL"), str):
            yield device, node
        for key, value in node.items():
            # MobileDeviceSoftwareVersions is keyed by device identifier.
            identifier = str(key)
            matched = IDENTIFIER.fullmatch(identifier) and os_key_for(identifier)
            yield from restore_entries(value, identifier if matched else device)
    elif isinstance(node, list):
        for value in node:
            yield from restore_entries(value, device)

def fetch(timeout: int) -> list[dict]:
    catalog = get_plist(CATALOG, timeout)
    candidates: dict[tuple[str, str], dict] = {}
    for device, entry in restore_entries(catalog):
        url = entry.get("FirmwareURL", "")
        version, build = entry.get("ProductVersion"), entry.get("BuildVersion")
        if not device or not url.endswith(".ipsw") or not version or not build:
            continue
        # The same device and build can appear under several catalog versions.
        candidates[(device, str(build))] = {
            "device": device,
            # Apple does not publish marketing names here; another source may.
            "name": None,
            "version": str(version),
            "build": str(build),
            "url": url,
            # FirmwareSHA1 is supplied by Apple's restore catalog for most
            # current public restore images. Keep it with the Apple CDN URL so
            # downloaded files can be verified without trusting a mirror.
            "sha1": str(entry.get("FirmwareSHA1", "")).lower(),
            "released_at": None,
            # Apple only lists what it will currently restore.
            "signed": True,
            "source": "apple",
        }
    return list(candidates.values())
