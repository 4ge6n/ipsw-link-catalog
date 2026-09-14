"""Ask Apple's signing server directly whether a build is still signed.

Apple's restore catalog lists only the build it currently offers for each
device, so it cannot say whether a build it has stopped offering is still
being signed. The signing server itself can: a TSS request for a build Apple
still signs is answered SUCCESS, and one it has stopped signing is refused.

The request needs the BuildManifest from inside the IPSW, which is fetched
with range requests rather than by downloading ten gigabytes.
"""
from __future__ import annotations
import plistlib
import random
import struct
import uuid
import zlib
from urllib.request import Request, urlopen

# Apple serves the signing server from an internal certificate authority, so
# this endpoint is plain HTTP by design. Only a yes/no verdict is read from it.
TSS_URL = "http://gs.apple.com/TSS/controller?action=2"
AGENT = "ipsw-link-catalog/1.0"
DIRECTORY_TAIL = 65536

def _range(url: str, start: int, end: int, timeout: int) -> bytes:
    request = Request(url, headers={"User-Agent": AGENT, "Range": f"bytes={start}-{end}"})
    with urlopen(request, timeout=timeout) as response:
        return response.read()

def _size(url: str, timeout: int) -> int:
    request = Request(url, method="HEAD", headers={"User-Agent": AGENT})
    with urlopen(request, timeout=timeout) as response:
        return int(response.headers["Content-Length"])

def _zip64_values(extra: bytes, uncompressed: int, compressed: int, offset: int) -> tuple[int, int, int]:
    position = 0
    while position + 4 <= len(extra):
        tag, length = struct.unpack("<HH", extra[position:position + 4])
        if tag == 0x0001:
            values = list(struct.unpack(f"<{length // 8}Q", extra[position + 4:position + 4 + length]))
            cursor = 0
            if uncompressed == 0xFFFFFFFF: uncompressed, cursor = values[cursor], cursor + 1
            if compressed == 0xFFFFFFFF: compressed, cursor = values[cursor], cursor + 1
            if offset == 0xFFFFFFFF: offset = values[cursor]
            break
        position += 4 + length
    return uncompressed, compressed, offset

def build_manifest(url: str, timeout: int = 60) -> dict:
    """Read BuildManifest.plist out of a remote IPSW without downloading it."""
    size = _size(url, timeout)
    tail = _range(url, max(0, size - DIRECTORY_TAIL), size - 1, timeout)
    end_record = tail.rfind(b"PK\x05\x06")
    if end_record < 0: raise ValueError("no end-of-central-directory record")
    directory_size, directory_offset = struct.unpack("<II", tail[end_record + 12:end_record + 20])
    # An IPSW is well past four gigabytes, so the zip64 records are the real ones.
    locator = tail.rfind(b"PK\x06\x07")
    if locator >= 0:
        zip64_offset = struct.unpack("<Q", tail[locator + 8:locator + 16])[0]
        header = _range(url, zip64_offset, zip64_offset + 55, timeout)
        if header.startswith(b"PK\x06\x06"):
            directory_size, directory_offset = struct.unpack("<QQ", header[40:56])
    directory = _range(url, directory_offset, directory_offset + directory_size - 1, timeout)
    name_at = directory.find(b"BuildManifest.plist")
    if name_at < 0: raise ValueError("BuildManifest.plist is not in the archive")
    entry = directory.rfind(b"PK\x01\x02", 0, name_at)
    method, = struct.unpack("<H", directory[entry + 10:entry + 12])
    compressed, uncompressed = struct.unpack("<II", directory[entry + 20:entry + 28])
    name_length, extra_length, _ = struct.unpack("<HHH", directory[entry + 28:entry + 34])
    local_offset, = struct.unpack("<I", directory[entry + 42:entry + 46])
    extra = directory[entry + 46 + name_length:entry + 46 + name_length + extra_length]
    uncompressed, compressed, local_offset = _zip64_values(extra, uncompressed, compressed, local_offset)
    local = _range(url, local_offset, local_offset + 29, timeout)
    local_name, local_extra = struct.unpack("<HH", local[26:30])
    start = local_offset + 30 + local_name + local_extra
    payload = _range(url, start, start + compressed - 1, timeout)
    return plistlib.loads(zlib.decompress(payload, -15) if method == 8 else payload)

# Recent silicon carries a 32-byte nonce; A8-era hardware wants 20, and asking
# with the wrong length is answered with an internal error rather than a verdict.
NONCE_LENGTHS = (32, 20)

def _verdict(status: str | None) -> bool | None:
    # 0 is a ticket. 69 means the request was short of what recent silicon
    # needs, which Apple only answers for a build it is still signing; a build
    # it has stopped signing is refused with 94 before reaching that point.
    if status in ("0", "69"): return True
    if status in ("94", "126"): return False
    return None

def _request_body(identity: dict, nonce_length: int = 32) -> dict:
    body = {
        "@HostPlatformInfo": "mac",
        "@VersionInfo": "libauthinstall-1033.0.2",
        "@UUID": str(uuid.uuid4()).upper(),
        "@ApImg4Ticket": True,
        "ApBoardID": int(identity["ApBoardID"], 16),
        "ApChipID": int(identity["ApChipID"], 16),
        "ApSecurityDomain": int(identity["ApSecurityDomain"], 16),
        # A throwaway device and nonce: the answer is about the build, not us.
        "ApECID": random.getrandbits(64),
        "ApNonce": random.randbytes(nonce_length),
        "ApProductionMode": True,
        "ApSecurityMode": True,
        "SepNonce": random.randbytes(20),
        "UniqueBuildID": identity["UniqueBuildID"],
    }
    for name, entry in identity.get("Manifest", {}).items():
        info = entry.get("Info", {})
        if not (info.get("IsFirmwarePayload") or info.get("IsLoadedByiBoot") or name in ("SEP", "RestoreSEP")):
            continue
        component = {key: value for key, value in entry.items() if key != "Info"}
        component.setdefault("EPRO", True)
        component.setdefault("ESEC", True)
        body[name] = component
    return body

def signing_status(url: str, timeout: int = 60) -> bool | None:
    """True when Apple still signs the build, False when it refuses, None if unclear."""
    manifest = build_manifest(url, timeout)
    identities = manifest.get("BuildIdentities") or []
    if not identities: return None
    for nonce_length in NONCE_LENGTHS:
        request = Request(TSS_URL, data=plistlib.dumps(_request_body(identities[0], nonce_length)), headers={
            "Content-Type": 'text/xml; charset="utf-8"',
            "User-Agent": "InetURL/1.0",
        })
        with urlopen(request, timeout=timeout) as response:
            answer = response.read().decode("utf-8", "replace")
        fields = dict(part.split("=", 1) for part in answer.split("&") if "=" in part)
        verdict = _verdict(fields.get("STATUS"))
        if verdict is not None: return verdict
    return None
