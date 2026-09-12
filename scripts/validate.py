from __future__ import annotations
import json
from pathlib import Path
from .normalize import OS_ORDER, allowed_ipsw_url

def validate_api(root: Path, hosts: set[str]) -> list[str]:
    errors=[]
    for os_key in OS_ORDER:
        for channel in ("release", "beta"):
            directory=root / os_key / channel
            for name in (("latest.json", "all.json") if channel == "release" else ("all.json",)):
                path=directory/name
                try: doc=json.loads(path.read_text())
                except Exception as exc: errors.append(f"{path}: invalid JSON ({exc})"); continue
                seen=set()
                for release in doc.get("releases", []):
                    data=directory/release["data"]
                    if not data.is_file(): errors.append(f"{path}: missing {data}")
                    for fw in release.get("firmwares", []):
                        if fw["url"] in seen: errors.append(f"{path}: duplicate URL")
                        seen.add(fw["url"])
                        if not allowed_ipsw_url(fw["url"], hosts): errors.append(f"{path}: unsafe URL")
                        if channel == "release" and name == "latest.json" and not fw["signed"]: errors.append(f"{path}: unsigned latest release")
    return errors
