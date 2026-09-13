"""Create a human-readable static site from the canonical API documents."""
from __future__ import annotations
import html
import hashlib
import json
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo
from .normalize import OS_NAMES, OS_ORDER

ROOT = Path(__file__).parent.parent
APP_URL = "https://4ge6n.github.io/ipsw-link-catalog"
DOWNLOAD_QUEUE_ASSET = "download-queue.js"
DOWNLOAD_QUEUE_VERSION = hashlib.sha256((ROOT / "assets" / DOWNLOAD_QUEUE_ASSET).read_bytes()).hexdigest()[:12]
STYLE = "body{font-family:system-ui,sans-serif;max-width:1100px;margin:2rem auto;padding:0 1rem;color:#1d1d1f}a{color:#06c}table{border-collapse:collapse;width:100%}th,td{padding:.65rem;border-bottom:1px solid #ddd;text-align:left}code{font-size:.9em}.meta{color:#666}button{font:inherit;padding:.6rem .9rem;border:1px solid #777;border-radius:.5rem;background:#fff;color:#111}.download-queue{margin:1rem 0;padding:1rem;border:1px solid #ddd;border-radius:.6rem}.download-queue label{display:block;margin:.4rem 0}.download-queue ol{margin:.6rem 0;padding-left:1.4rem}.download-queue li{margin:.35rem 0;word-break:break-all}.download-queue .queue-remove{padding:.15rem .45rem;border-radius:.35rem;font-size:.85em}.queue-panel{display:grid;grid-template-rows:0fr;opacity:0;visibility:hidden;transition:grid-template-rows .28s cubic-bezier(.2,.7,.3,1),opacity .22s ease,visibility .28s}.queue-panel>div{overflow:hidden;min-height:0}.queue-list{max-height:55vh;overflow-y:auto;-webkit-overflow-scrolling:touch;overscroll-behavior:contain}.queue-panel.is-open{grid-template-rows:1fr;opacity:1;visibility:visible}.download-queue li{transition:opacity .18s ease,transform .18s ease}.download-queue li.is-leaving{opacity:0;transform:translateX(-.6rem)}.haptic-switch{position:fixed;width:1px;height:1px;opacity:0;pointer-events:none;left:-99px}@media (prefers-reduced-motion:reduce){.queue-panel,.download-queue li{transition:none}}"
def write(path: Path, title: str, body: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    head=f"<meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><meta name='theme-color' content='#ffffff'><meta name='apple-mobile-web-app-capable' content='yes'><meta name='apple-mobile-web-app-title' content='IPSW Links'><link rel='manifest' href='{APP_URL}/manifest.webmanifest'><link rel='apple-touch-icon' href='{APP_URL}/icon.svg'><title>{html.escape(title)}</title><style>{STYLE}</style><script defer src='{APP_URL}/push-config.js'></script><script defer src='{APP_URL}/push.js'></script><script defer src='{APP_URL}/{DOWNLOAD_QUEUE_ASSET}?v={DOWNLOAD_QUEUE_VERSION}'></script>"
    path.write_text(f"<!doctype html><html lang='en'><head>{head}</head><body>{body}</body></html>\n")
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
def queue_controls(scope: str = "table") -> str:
    """One control set drives every checkbox in its own table, or on the whole page."""
    return "<section class='download-queue'><strong>Download queue</strong><p class='meta'>Select files and add them to the queue. The queue is shared across every version and operating system on this site, so you can mix iOS and iPadOS files, then open one download at a time. After saving a file in Safari, return here and open the next one.</p><button type='button' data-download-queue-select-all>Select all</button> <button type='button' data-download-queue-clear>Clear selection</button> <button type='button' data-download-queue-add>Add selected to queue</button> <button type='button' data-download-queue-show aria-expanded='false'>Show queue<span data-download-queue-count></span></button> <button type='button' data-download-queue-next>Open next download</button> <button type='button' data-download-queue-reset>Empty queue</button><div class='queue-panel' data-download-queue-panel aria-hidden='true'><div data-download-queue-panel-body></div></div><p class='meta' data-download-queue-status></p></section>".replace("<section class='download-queue'>", f"<section class='download-queue' data-download-queue-scope='{scope}'>")
def firmware_table(release: dict, controls: bool = True) -> str:
    rows=[]
    for fw in release["firmwares"]:
        devices="<br>".join(html.escape(x) for x in fw["devices"])
        queue=f"<input class='download-queue-item' type='checkbox' aria-label='Select {html.escape(fw['filename'], quote=True)}' data-url='{html.escape(fw['url'], quote=True)}' data-name='{html.escape(fw['filename'], quote=True)}'>"
        rows.append(f"<tr><td>{queue}</td><td>{html.escape(fw['name'])}</td><td><code>{devices}</code></td><td>{link(fw['url'], fw['filename'])}</td><td>{'Signed' if fw['signed'] else 'Not signed'}</td></tr>")
    return (queue_controls() if controls else "") + "<table><thead><tr><th>Select</th><th>Device</th><th>Identifiers</th><th>Apple download</th><th>Status</th></tr></thead><tbody>" + "".join(rows) + "</tbody></table>"
def release_list_item(release: dict, href: str) -> str:
    return f"<li>{link(href, display_version(release)+' ('+release['build']+')')} — {len(release['firmwares'])} download link(s)</li>"
def generate(api: Path, output: Path):
    if output.exists(): shutil.rmtree(output)
    shutil.copytree(ROOT/"assets", output, dirs_exist_ok=True)
    release_meta=json.loads((api/"ios"/"release"/"all.json").read_text())
    updated=f"<p class='meta'>Catalog updated: UTC {html.escape(release_meta['generated_at'])} · Asia/Tokyo {html.escape(release_meta.get('generated_at_tokyo', 'unknown'))}</p>"
    combined=[]
    home=["<h1> IPSW download links</h1><p>Direct Apple CDN links, organized by OS, release channel, version, and build. IPSW files are not hosted here.</p><p><a href='#latest'>Jump to the latest supported downloads</a> for every operating system.</p>", "<section><h2>Update notifications</h2><p>Add this site to your iPhone Home Screen, open it as an app, then enable notifications.</p><button id='enable-notifications' type='button'>Enable update notifications</button><p id='push-status' class='meta'></p></section>", updated, "<ul>"]
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
                    releases=sorted(groups[major], key=beta_release_order, reverse=True) if channel == "beta" else groups[major]
                    kind="beta/RC build(s)" if channel == "beta" else "release build(s)"
                    channel_page.append(f"<li>{link(major+'/', major+'.x')} — {len(releases)} {kind}</li>")
                    major_title = f"{OS_NAMES[os_key]} {major}.x beta / RC" if channel == "beta" else f"{OS_NAMES[os_key]} {major}.x Release"
                    major_back = "← Beta major versions" if channel == "beta" else "← Release major versions"
                    major_body=[f"<p>{link('../', major_back)}</p><h1>{major_title}</h1><ul>"]
                    if channel == "beta":
                        by_version={}
                        for release in releases: by_version.setdefault(release["version"], []).append(release)
                        for version in sorted(by_version, key=lambda value: tuple(int(part) for part in value.split(".")), reverse=True):
                            builds=by_version[version]
                            major_body.append(f"<li>{link(version+'/', version)} — {len(builds)} beta/RC build(s)</li>")
                            version_body=[f"<p>{link('../', '← '+major+'.x beta / RC')}</p><h1>{OS_NAMES[os_key]} {version} beta / RC</h1><ul>"]
                            for release in builds:
                                href="../../"+release["data"].removesuffix(".json")+"/"
                                version_body.append(release_list_item(release, href))
                            write(output/os_key/channel/major/version/"index.html", f"{OS_NAMES[os_key]} {version} beta / RC", "".join(version_body)+"</ul>")
                    else:
                        for release in releases:
                            href="../"+release["data"].removesuffix(".json")+"/"
                            major_body.append(release_list_item(release, href))
                    write(output/os_key/channel/major/"index.html", f"{OS_NAMES[os_key]} {major}.x {channel.title()}", "".join(major_body)+"</ul>")
            if channel == "release":
                latest=json.loads((api/os_key/channel/"latest.json").read_text())
                latest_body=f"<p>{link('../', '← '+channel.title()+' list')}</p><h1>Latest {OS_NAMES[os_key]} {channel.title()} downloads</h1>"+queue_controls("page")+"".join(f"<h2>{html.escape(r['version'])} ({html.escape(r['build'])})</h2><p class='meta'>{release_time(r.get('released_at'))}</p>"+firmware_table(r, controls=False) for r in latest["releases"])
                write(output/os_key/channel/"latest"/"index.html", f"Latest {OS_NAMES[os_key]} {channel}", latest_body or "<p>No downloads available.</p>")
                if latest["releases"]:
                    combined.append(f"<h3 id='latest-{os_key}'>{OS_NAMES[os_key]}</h3>"+"".join(f"<h4>{html.escape(r['version'])} ({html.escape(r['build'])})</h4><p class='meta'>{release_time(r.get('released_at'))}</p>"+firmware_table(r, controls=False) for r in latest["releases"]))
            write(output/os_key/channel/"index.html", f"{OS_NAMES[os_key]} {channel}", "".join(channel_page)+"</ul>")
    # One page with every signed release, so a queue can be built without hopping between operating systems.
    all_latest="<h2 id='latest'>Latest supported downloads</h2><p class='meta'>Every operating system's currently supported releases. Beta and RC builds are not listed here.</p>"+queue_controls("page")+"".join(combined)
    write(output/"index.html", " IPSW download links", "".join(home)+"</ul>"+all_latest)
