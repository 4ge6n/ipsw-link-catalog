from __future__ import annotations
from .normalize import OS_ORDER, OS_NAMES

START, END = "<!-- AUTO-GENERATED:START -->", "<!-- AUTO-GENERATED:END -->"
def content(indexes, now, now_tokyo, owner_repo="OWNER/REPOSITORY", branch="main"):
    lines=[START, "## Catalog status", "", f"Last successful update (UTC): `{now}`", f"Last successful update (Asia/Tokyo): `{now_tokyo}`", "", "### Endpoints", ""]
    for os_key in OS_ORDER:
        lines += [f"#### {OS_NAMES[os_key]}", ""]
        for channel in ("release", "beta"):
            root=f"https://raw.githubusercontent.com/{owner_repo}/{branch}/api/{os_key}/{channel}"
            data=indexes[(os_key, channel)]
            if channel == "release": lines.append(f"- `{channel}`: [latest.json]({root}/latest.json) · [all.json]({root}/all.json) ({data['firmware_count']} IPSW records)")
            else: lines.append(f"- `{channel}`: [all.json]({root}/all.json) ({data['firmware_count']} IPSW records; no beta latest endpoint)")
        lines.append("")
    lines += ["### Refresh", "", "Public firmware sources are polled every five minutes (GitHub Actions scheduling is best-effort). An authenticated external feed relay can request an immediate refresh with the `firmware_release` repository-dispatch event; Apple does not provide this repository a direct IPSW-release webhook.", "", "### Record fields", "", "Use `firmwares[].id` to identify a firmware, `devices` to match hardware, and `signed` to determine current restore availability. URLs are restricted to Apple CDN HTTPS IPSWs.", "", "Data is assembled from public firmware metadata. It is not affiliated with Apple; verify compatibility before restoring.", END]
    return "\n".join(lines) + "\n"

def replace(existing, generated):
    if START in existing and END in existing:
        before=existing[:existing.index(START)]; after=existing[existing.index(END)+len(END):]
        return before + generated + (after.strip() + "\n" if after.strip() else "")
    return existing.rstrip()+"\n\n"+generated
