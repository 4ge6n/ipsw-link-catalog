"""Create a human-readable static site from the canonical API documents."""
from __future__ import annotations
import html
import json
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo
from .normalize import OS_NAMES, OS_ORDER

STYLE = "body{font-family:system-ui,sans-serif;max-width:1100px;margin:2rem auto;padding:0 1rem;color:#1d1d1f}a{color:#06c}table{border-collapse:collapse;width:100%}th,td{padding:.65rem;border-bottom:1px solid #ddd;text-align:left}code{font-size:.9em}.meta{color:#666}"
def write(path: Path, title: str, body: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"<!doctype html><html lang='en'><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>{html.escape(title)}</title><style>{STYLE}</style><body>{body}</body></html>\n")
def link(href: str, text: str) -> str: return f"<a href='{html.escape(href, quote=True)}'>{html.escape(text)}</a>"
def display_version(release: dict) -> str:
    """Turn URL-safe beta labels into the names people expect to see."""
    label=release["data"].rsplit("/", 1)[0]
    match=re.fullmatch(r"(.+?)-(public-)?beta(?:-(\d+))?", label)
    if match:
        number, public, sequence=match.groups()
        return f"{number} {'Public ' if public else ''}Beta" + (f" {sequence}" if sequence else "")
    match=re.fullmatch(r"(.+?)-rc(?:-(\d+))?", label)
    if match:
        number, sequence=match.groups()
        return f"{number} RC" + (f" {sequence}" if sequence else "")
    return release["version"]
def beta_release_order(release: dict) -> tuple:
    """Order beta pages by their release sequence, not lexical build ID."""
    label=release["data"].rsplit("/", 1)[0]
    beta=re.fullmatch(r".+?-(?:public-)?beta(?:-(\d+))?", label)
    rc=re.fullmatch(r".+?-rc(?:-(\d+))?", label)
    phase, sequence=(0, int(beta.group(1) or 1)) if beta else ((1, int(rc.group(1) or 1)) if rc else (2, 0))
    version=tuple(int(part) for part in release["version"].split("."))
    return version, phase, sequence, release["build"]
def release_time(value: str | None) -> str:
    if not value:
        return "Release time: unknown (the source did not publish a time)"
    try:
        released=datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return "Release time: " + html.escape(value)
    tokyo=released.astimezone(ZoneInfo("Asia/Tokyo"))
    return f"Released (UTC): {released.isoformat().replace('+00:00', 'Z')}<br>Released (Asia/Tokyo): {tokyo.isoformat()}"
def firmware_table(release: dict) -> str:
    rows=[]
    for fw in release["firmwares"]:
        devices="<br>".join(html.escape(x) for x in fw["devices"])
        rows.append(f"<tr><td>{html.escape(fw['name'])}</td><td><code>{devices}</code></td><td>{link(fw['url'], fw['filename'])}</td><td>{'Signed' if fw['signed'] else 'Not signed'}</td></tr>")
    return "<table><thead><tr><th>Device</th><th>Identifiers</th><th>Apple download</th><th>Status</th></tr></thead><tbody>" + "".join(rows) + "</tbody></table>"
def release_list_item(release: dict, href: str) -> str:
    return f"<li>{link(href, display_version(release)+' ('+release['build']+')')} — {len(release['firmwares'])} download link(s)</li>"
def generate(api: Path, output: Path):
    if output.exists(): shutil.rmtree(output)
    release_meta=json.loads((api/"ios"/"release"/"all.json").read_text())
    updated=f"<p class='meta'>Catalog updated: UTC {html.escape(release_meta['generated_at'])} · Asia/Tokyo {html.escape(release_meta.get('generated_at_tokyo', 'unknown'))}</p>"
    home=["<h1> IPSW download links</h1><p>Direct Apple CDN links, organized by OS, release channel, version, and build. IPSW files are not hosted here.</p>", updated, "<ul>"]
    for os_key in OS_ORDER:
        home.append(f"<li>{link(os_key+'/', OS_NAMES[os_key])}</li>")
        os_page=[f"<p>{link('../', '← All operating systems')}</p><h1>{OS_NAMES[os_key]}</h1><ul>"]
        for channel in ("release", "beta"):
            os_page.append(f"<li>{link(channel+'/', channel.title())}</li>")
        write(output/os_key/"index.html", OS_NAMES[os_key], "".join(os_page)+"</ul>")
        for channel in ("release", "beta"):
            document=json.loads((api/os_key/channel/"all.json").read_text())
            latest_link=f"<p>{link('latest/', 'Latest supported downloads')}</p>" if channel == "release" else "<p class='meta'>Beta and RC are listed by build; no single latest endpoint is published.</p>"
            channel_page=[f"<p>{link('../', '← '+OS_NAMES[os_key])}</p><h1>{OS_NAMES[os_key]} {channel.title()}</h1>{latest_link}<ul>"]
            for release in document["releases"]:
                href=f"{release['data'].removesuffix('.json')}/"
                shown_version=display_version(release)
                page=f"<p>{link('../../', '← '+channel.title()+' list')}</p><h1>{OS_NAMES[os_key]} {channel.title()} {html.escape(shown_version)} ({html.escape(release['build'])})</h1><p class='meta'>{release_time(release.get('released_at'))}</p>"+firmware_table(release)
                write(output/os_key/channel/release["data"].removesuffix(".json")/"index.html", f"{OS_NAMES[os_key]} {shown_version} ({release['build']})", page)
            # Both channels are navigated by OS major version.  Release keeps
            # its separate Latest view, while beta intentionally has no such
            # endpoint because several candidates may coexist.
            if channel in ("release", "beta"):
                groups={}
                for release in document["releases"]:
                    major=release["version"].split(".", 1)[0]
                    groups.setdefault(major, []).append(release)
                channel_page=[f"<p>{link('../', '← '+OS_NAMES[os_key])}</p><h1>{OS_NAMES[os_key]} {channel.title()}</h1>{latest_link}<p>Select a major version.</p><ul>"]
                for major in sorted(groups, key=lambda value: int(value) if value.isdigit() else -1, reverse=True):
                    releases=sorted(groups[major], key=beta_release_order) if channel == "beta" else groups[major]
                    kind="beta/RC build(s)" if channel == "beta" else "release build(s)"
                    channel_page.append(f"<li>{link(major+'/', major+'.x')} — {len(releases)} {kind}</li>")
                    major_title = f"{OS_NAMES[os_key]} {major}.x beta / RC" if channel == "beta" else f"{OS_NAMES[os_key]} {major}.x Release"
                    major_back = "← Beta major versions" if channel == "beta" else "← Release major versions"
                    major_body=[f"<p>{link('../', major_back)}</p><h1>{major_title}</h1><ul>"]
                    for release in releases:
                        href="../"+release["data"].removesuffix(".json")+"/"
                        major_body.append(release_list_item(release, href))
                    write(output/os_key/channel/major/"index.html", f"{OS_NAMES[os_key]} {major}.x beta / RC", "".join(major_body)+"</ul>")
            if channel == "release":
                latest=json.loads((api/os_key/channel/"latest.json").read_text())
                latest_body=f"<p>{link('../', '← '+channel.title()+' list')}</p><h1>Latest {OS_NAMES[os_key]} {channel.title()} downloads</h1>"+"".join(f"<h2>{html.escape(r['version'])} ({html.escape(r['build'])})</h2><p class='meta'>{release_time(r.get('released_at'))}</p>"+firmware_table(r) for r in latest["releases"])
                write(output/os_key/channel/"latest"/"index.html", f"Latest {OS_NAMES[os_key]} {channel}", latest_body or "<p>No downloads available.</p>")
            write(output/os_key/channel/"index.html", f"{OS_NAMES[os_key]} {channel}", "".join(channel_page)+"</ul>")
    write(output/"index.html", " IPSW download links", "".join(home)+"</ul>")
