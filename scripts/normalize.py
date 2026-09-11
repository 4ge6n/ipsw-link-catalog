"""Normalization and safety checks for firmware candidates."""
from __future__ import annotations
import re
from urllib.parse import urlparse

OS_ORDER = ("ios", "ipados", "tvos", "visionos", "audioos", "macos")
OS_NAMES = {"ios": "iOS", "ipados": "iPadOS", "tvos": "tvOS", "visionos": "visionOS", "audioos": "audioOS", "macos": "macOS"}

def os_key_for(device: str) -> str | None:
    for prefix, key in (("iPhone", "ios"), ("iPod", "ios"), ("iPad", "ipados"), ("AppleTV", "tvos"), ("RealityDevice", "visionos"), ("AudioAccessory", "audioos"), ("UniversalMac", "macos"), ("Mac", "macos")):
        if device.startswith(prefix): return key
    return None

def safe_label(value: str) -> str:
    value = value.strip().lower().replace(" ", "-").replace("_", "-")
    value = re.sub(r"[^a-z0-9.\-]", "-", value)
    return re.sub(r"-+", "-", value).strip("-")

def safe_build(value: str) -> str:
    """Build identifiers are case-sensitive identifiers, unlike URL labels."""
    return re.sub(r"[^A-Za-z0-9._-]", "-", value.strip())

def classify(version: str, label: str = "") -> tuple[str, str, bool]:
    text = f"{version} {label}".lower()
    base = re.match(r"\d+(?:\.\d+)*", version)
    number = base.group(0) if base else safe_label(version)
    rc = re.search(r"\b(?:rc|release[ -]?candidate)\s*(\d+)?", text)
    beta = re.search(r"(?:public[ -]?)?beta\s*(\d+)?|developer[ -]?seed", text)
    if rc: return "beta", number + "-rc" + ("-" + rc.group(1) if rc.group(1) else ""), True
    if beta:
        public = "public-" if "public" in text else ""
        return "beta", number + "-" + public + "beta" + ("-" + beta.group(1) if beta.group(1) else ""), False
    return "release", number, False

def allowed_ipsw_url(url: str, hosts: set[str]) -> bool:
    parsed = urlparse(url)
    return parsed.scheme == "https" and parsed.hostname in hosts and parsed.path.lower().endswith(".ipsw")

def version_key(value: str) -> tuple:
    return tuple(int(part) if part.isdigit() else part for part in re.split(r"(\d+)", value))
