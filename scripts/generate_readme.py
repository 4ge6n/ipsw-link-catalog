from __future__ import annotations
from .normalize import OS_ORDER, OS_NAMES

START, END = "<!-- AUTO-GENERATED:START -->", "<!-- AUTO-GENERATED:END -->"
def content(indexes, now, owner_repo="OWNER/REPOSITORY", branch="main"):
    lines=[START, "## Catalog status", "", f"Last successful update: `{now}`", "", "### Endpoints", ""]
    for os_key in OS_ORDER:
        lines += [f"#### {OS_NAMES[os_key]}", ""]
        for channel in ("release", "beta"):
            root=f"https://raw.githubusercontent.com/{owner_repo}/{branch}/api/{os_key}/{channel}"
            data=indexes[(os_key, channel)]
            lines.append(f"- `{channel}`: [latest.json]({root}/latest.json) · [all.json]({root}/all.json) ({data['firmware_count']} IPSW records)")
        lines.append("")
    lines += ["### Record fields", "", "Use `firmwares[].id` to identify a firmware, `devices` to match hardware, and `signed` to determine current restore availability. URLs are restricted to Apple CDN HTTPS IPSWs.", "", "Data is assembled from public firmware metadata. It is not affiliated with Apple; verify compatibility before restoring.", END]
    return "\n".join(lines) + "\n"

def replace(existing, generated):
    if START in existing and END in existing:
        before=existing[:existing.index(START)]; after=existing[existing.index(END)+len(END):]
        return before + generated + after
    return existing.rstrip()+"\n\n"+generated
