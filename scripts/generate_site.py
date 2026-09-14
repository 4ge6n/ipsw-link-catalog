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
UPDATE_CHECK_ASSET = "update-check.js"
LOCAL_TIME_ASSET = "local-time.js"
def asset_version(name: str) -> str:
    return hashlib.sha256((ROOT / "assets" / name).read_bytes()).hexdigest()[:12]
DOWNLOAD_QUEUE_VERSION = asset_version(DOWNLOAD_QUEUE_ASSET)
UPDATE_CHECK_VERSION = asset_version(UPDATE_CHECK_ASSET)
LOCAL_TIME_VERSION = asset_version(LOCAL_TIME_ASSET)
CATALOG_BUILD = ""
STYLE = """
:root{color-scheme:light dark;--bg:#f5f5f7;--surface:#fff;--text:#1d1d1f;--muted:#6e6e73;--line:#d9d9de;--accent:#0071e3;--accent-text:#fff;--accent-soft:#eaf3ff;--radius:14px}
@media (prefers-color-scheme:dark){:root{--bg:#000;--surface:#1c1c1e;--text:#f5f5f7;--muted:#9b9ba1;--line:#38383d;--accent:#0a84ff;--accent-text:#fff;--accent-soft:#10233b}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:17px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;-webkit-text-size-adjust:100%;padding:max(1rem,env(safe-area-inset-top)) max(1rem,env(safe-area-inset-right)) max(2rem,env(safe-area-inset-bottom)) max(1rem,env(safe-area-inset-left))}
main,body>*{max-width:1100px;margin-inline:auto}
h1{font-size:clamp(1.7rem,5vw,2.2rem);line-height:1.15;letter-spacing:-.02em;margin:1.2rem 0 .6rem}
h2{font-size:clamp(1.25rem,3.6vw,1.5rem);letter-spacing:-.01em;margin:2rem 0 .6rem}
h3{font-size:1.2rem;margin:2rem 0 .4rem}
h4{font-size:1.02rem;margin:1.4rem 0 .3rem;color:var(--muted);font-weight:600}
p{margin:.5rem 0}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
code{font:.92em/1.4 ui-monospace,SFMono-Regular,Menlo,monospace}
.meta{color:var(--muted);font-size:.9rem}time[data-local-time]{color:var(--text);font-variant-numeric:tabular-nums}.when-ago,.when-utc{color:var(--muted)}.when-ago::before,.when-utc::before{content:' · '}
ul{list-style:none;padding:0;margin:.8rem 0;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);overflow:hidden}
ul li{border-top:1px solid var(--line)}
ul li:first-child{border-top:0}
ul li a{display:block;padding:.9rem 1rem;min-height:44px}
ul li a:hover{background:var(--accent-soft);text-decoration:none}
button{font:inherit;font-size:1rem;min-height:44px;padding:.6rem 1.1rem;border:1px solid var(--line);border-radius:11px;background:var(--surface);color:var(--text);cursor:pointer;-webkit-tap-highlight-color:transparent;transition:transform .12s ease,background .15s ease}
button:active{transform:scale(.97)}
button:focus-visible{outline:3px solid var(--accent);outline-offset:2px}
[data-download-queue-add],[data-download-queue-all],[data-download-queue-next],#enable-notifications{background:var(--accent);border-color:transparent;color:var(--accent-text);font-weight:600}
.download-queue,section{background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);padding:1rem;margin:1.2rem 0}
.queue-actions{display:flex;flex-wrap:wrap;gap:.5rem;margin-top:.8rem;align-items:center}.queue-batch{display:flex;align-items:center;gap:.4rem;min-height:44px;padding:0 .8rem;border:1px solid var(--line);border-radius:11px;background:var(--surface);color:var(--muted);font-size:.9rem}.queue-batch select{font:inherit;font-size:1rem;color:var(--text);background:none;border:0;min-height:40px;padding:0 .2rem}.queue-batch[hidden]{display:none}.queue-offline{margin-top:1rem;border-top:1px solid var(--line);padding-top:.8rem}.queue-offline summary{cursor:pointer;font-weight:600;min-height:32px;padding:.3rem 0}.queue-steps{list-style:decimal;margin:1rem 0;padding-left:1.5rem;background:none;border:0;border-radius:0}.queue-steps>li{margin:0 0 1.2rem;padding-left:.2rem;border:0}.queue-steps>li::marker{color:var(--muted);font-weight:600}.queue-field{display:flex;flex-direction:column;gap:.3rem;margin:.6rem 0;font-size:.85rem;color:var(--muted)}.queue-field select,.queue-field input{font:inherit;font-size:1rem;color:var(--text);min-height:44px;padding:.5rem .8rem;border:1px solid var(--line);border-radius:11px;background:var(--surface);width:100%}.queue-warn{display:block;margin-top:.3rem;padding:.5rem .7rem;border-radius:9px;background:var(--accent-soft);color:var(--text);font-size:.85rem}.queue-advanced{margin:.6rem 0 0}.queue-advanced summary{font-weight:400;font-size:.9rem;color:var(--muted);cursor:pointer;min-height:32px}.queue-offline code.inline{display:inline;padding:.1rem .35rem;margin:0;background:var(--bg);border-radius:6px;white-space:normal}.queue-offline code{display:block;overflow-x:auto;padding:.6rem .8rem;margin:.4rem 0;background:var(--bg);border-radius:9px;white-space:pre}.queue-field input:focus-visible,.queue-field select:focus-visible{outline:3px solid var(--accent);outline-offset:1px}
table{border-collapse:collapse;width:100%;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);overflow:hidden;margin:.8rem 0}
th,td{padding:.8rem .9rem;border-top:1px solid var(--line);text-align:left;vertical-align:middle}
thead th{border-top:0;font-size:.8rem;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);background:var(--bg)}
tbody tr:first-child td{border-top:0}
td a{word-break:break-all}
input[type=checkbox]{width:24px;height:24px;accent-color:var(--accent);margin:0}
td:first-child{width:44px;text-align:center}
.queue-panel{display:grid;grid-template-rows:0fr;opacity:0;visibility:hidden;transition:grid-template-rows .28s cubic-bezier(.2,.7,.3,1),opacity .22s ease,visibility .28s}
.queue-panel>div{overflow:hidden;min-height:0}
.queue-panel.is-open{grid-template-rows:1fr;opacity:1;visibility:visible}
.queue-list{max-height:55vh;overflow-y:auto;-webkit-overflow-scrolling:touch;overscroll-behavior:contain;list-style:none;margin:.8rem 0 0;padding:0;border:1px solid var(--line);border-radius:11px;background:var(--bg)}
.queue-list li{display:flex;gap:.6rem;align-items:center;justify-content:space-between;padding:.6rem .8rem;border-top:1px solid var(--line);transition:opacity .18s ease,transform .18s ease}
.queue-list li:first-child{border-top:0}
.queue-list li.is-leaving{opacity:0;transform:translateX(-.6rem)}
.queue-list a{word-break:break-all;font-size:.92rem}
.queue-remove{min-height:32px;padding:.25rem .6rem;font-size:.85rem;flex:none}
.haptic-switch{position:fixed;width:1px;height:1px;opacity:0;pointer-events:none;left:-99px}
.update-bar{display:none;position:fixed;z-index:10;left:max(.8rem,env(safe-area-inset-left));right:max(.8rem,env(safe-area-inset-right));bottom:max(.8rem,env(safe-area-inset-bottom));max-width:640px;margin-inline:auto;padding:.8rem 1rem;gap:.8rem;align-items:center;justify-content:space-between;flex-wrap:wrap;border:1px solid var(--accent);border-radius:var(--radius);background:var(--accent-soft);color:var(--text);box-shadow:0 6px 24px rgba(0,0,0,.12)}
.update-bar.is-stale{display:flex;animation:update-bar-in .3s cubic-bezier(.2,.7,.3,1)}@keyframes update-bar-in{from{opacity:0;transform:translateY(1rem)}to{opacity:1;transform:none}}
.update-bar button{background:var(--accent);border-color:transparent;color:var(--accent-text);font-weight:600}
@media (max-width:700px){
 body{font-size:16px}
 table,thead,tbody,tr,td{display:block}
 thead{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}
 table{border:0;background:none;padding:0}
 tbody tr{background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);margin:.6rem 0;padding:.3rem .2rem;position:relative}
 td{border-top:0;padding:.35rem .9rem}
 tbody tr td:first-child{position:absolute;top:.6rem;right:.5rem;width:auto}
 td[data-label]::before{content:attr(data-label);display:block;font-size:.72rem;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}
 td[data-label=Device]{font-weight:600;padding-right:3rem}
 .queue-actions button{flex:1 1 calc(50% - .5rem)}
}
@media (prefers-reduced-motion:reduce){.queue-panel,.queue-list li,button{transition:none}.update-bar.is-stale{animation:none}}
"""
def write(path: Path, title: str, body: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    head=f"<meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><meta name='theme-color' content='#ffffff'><meta name='catalog-build' content='{CATALOG_BUILD}' data-base='{APP_URL}/'><meta name='apple-mobile-web-app-capable' content='yes'><meta name='apple-mobile-web-app-title' content='IPSW Links'><link rel='manifest' href='{APP_URL}/manifest.webmanifest'><link rel='apple-touch-icon' href='{APP_URL}/icon.svg'><title>{html.escape(title)}</title><style>{STYLE}</style><script defer src='{APP_URL}/push-config.js'></script><script defer src='{APP_URL}/push.js'></script><script defer src='{APP_URL}/{DOWNLOAD_QUEUE_ASSET}?v={DOWNLOAD_QUEUE_VERSION}'></script><script defer src='{APP_URL}/{UPDATE_CHECK_ASSET}?v={UPDATE_CHECK_VERSION}'></script><script defer src='{APP_URL}/{LOCAL_TIME_ASSET}?v={LOCAL_TIME_VERSION}'></script>"
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
def stamp(moment: datetime) -> str:
    """Readable in Tokyo time, rewritten to the reader's own zone by script."""
    tokyo=moment.astimezone(ZoneInfo("Asia/Tokyo"))
    iso=moment.isoformat().replace("+00:00", "Z")
    # UTC is the same for every reader, so it is rendered once and left alone.
    return (f"<time datetime='{iso}' data-local-time>{tokyo.strftime('%b %-d, %Y %H:%M')} JST</time>"
            f"<span class='when-utc' data-utc-time>{moment.strftime('%b %-d, %Y %H:%M')} UTC</span>")
def release_time(value: str | None) -> str:
    if not value:
        return "Release time: unknown (the source did not publish a time)"
    try:
        released=datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return "Release time: " + html.escape(value)
    return "Released " + stamp(released)
def device_key(value: str) -> tuple:
    """Sort iPhone17,2 after iPhone9,1 by comparing digits as numbers."""
    return tuple((1, int(part), "") if part.isdigit() else (0, 0, part) for part in re.split(r"(\d+)", value) if part)
def queue_controls(scope: str = "table") -> str:
    """One control set drives every checkbox in its own table, or on the whole page."""
    return "<section class='download-queue'><strong>Download queue</strong><p class='meta'>Select files and add them to the queue. The queue is shared across every version and operating system on this site, so you can mix iOS and iPadOS files, then open one download at a time. After saving a file in Safari, return here and open the next one.</p><div class='queue-actions'><button type='button' data-download-queue-select-all>Select all</button> <button type='button' data-download-queue-clear>Clear selection</button> <button type='button' data-download-queue-add>Add selected to queue</button> <button type='button' data-download-queue-show aria-expanded='false'>Show queue<span data-download-queue-count></span></button> <button type='button' data-download-queue-all>Download all</button> <label class='queue-batch'>At once <select data-download-queue-batch><option value='1'>1</option><option value='2'>2</option><option value='3' selected>3</option><option value='5'>5</option><option value='all'>All</option></select></label> <button type='button' data-download-queue-next>Open next download</button> <button type='button' data-download-queue-reset>Empty queue</button></div><details class='queue-offline'><summary>Download the whole queue unattended</summary><p class='meta'>A browser is never told when a download has finished, so it cannot start the next one on its own. This script can: it works through the queue for you, shows progress, and carries on where it left off.</p><ol class='queue-steps'><li><strong>Choose how many download at once.</strong><label class='queue-field'><select data-download-queue-jobs><option value='1'>1 at a time — one progress bar, easiest to follow</option><option value='2' selected>2 at a time</option><option value='3'>3 at a time</option><option value='4'>4 at a time</option><option value='6'>6 at a time — needs a fast connection</option></select></label><label class='queue-field'>If the file is already in that folder<select data-download-queue-existing><option value='skip' selected>Skip it — finish a partial file, leave a complete one</option><option value='redownload'>Download it again from scratch</option></select></label><label class='queue-field'>Older builds of the same device<select data-download-queue-prune><option value='keep' selected>Keep them</option><option value='delete'>Delete each one once its replacement has downloaded</option></select><span class='queue-warn' data-download-queue-prune-note hidden>Deletes other <code class='inline'>.ipsw</code> files in that folder for the same device. Anything in this queue is never touched, and each deletion is printed.</span></label></li><li><strong>Save the script where you want the files.</strong> <span data-download-queue-save-hint>The downloads land in the same folder as the script.</span><div class='queue-actions'><button type='button' data-download-queue-export>Save the script</button></div><details class='queue-advanced'><summary>Or type the folder to download into</summary><label class='queue-field'>Folder to download into<input type='text' data-download-queue-dest placeholder='/Volumes/IPSW' spellcheck='false' autocapitalize='off' autocorrect='off'></label><p class='meta'>Set this and the script ignores where it was saved, downloading into this folder instead.</p></details></li><li><strong>Run it in Terminal.</strong> Type <code class='inline'>bash</code> and a space, drag the saved script onto the Terminal window, then press Return.<p class='meta'><code data-download-queue-command>bash ipsw-queue.sh</code></p></li></ol><p class='meta'>It names each file with its size, counts off what is finished, and leaves completed files alone — so you can stop it at any time and run it again to collect the rest.</p><div class='queue-actions'><button type='button' data-download-queue-list>Save just the URLs (.txt), for aria2c or wget</button></div></details><div class='queue-panel' data-download-queue-panel aria-hidden='true'><div data-download-queue-panel-body></div></div><p class='meta' data-download-queue-status></p></section>".replace("<section class='download-queue'>", f"<section class='download-queue' data-download-queue-scope='{scope}'>")
def firmware_table(release: dict, controls: bool = True) -> str:
    rows=[]
    # Newest hardware first, so the device most people want is at the top.
    for fw in sorted(release["firmwares"], key=lambda f: device_key(f["devices"][0]), reverse=True):
        devices="<br>".join(html.escape(x) for x in fw["devices"])
        queue=f"<input class='download-queue-item' type='checkbox' aria-label='Select {html.escape(fw['filename'], quote=True)}' data-url='{html.escape(fw['url'], quote=True)}' data-name='{html.escape(fw['filename'], quote=True)}'>"
        rows.append(f"<tr><td>{queue}</td><td data-label='Device'>{html.escape(fw['name'])}</td><td data-label='Identifiers'><code>{devices}</code></td><td data-label='Apple download'>{link(fw['url'], fw['filename'])}</td><td data-label='Status'>{'Signed' if fw['signed'] else 'Not signed'}</td></tr>")
    return (queue_controls() if controls else "") + "<table><thead><tr><th>Select</th><th>Device</th><th>Identifiers</th><th>Apple download</th><th>Status</th></tr></thead><tbody>" + "".join(rows) + "</tbody></table>"
def release_list_item(release: dict, href: str) -> str:
    return f"<li>{link(href, display_version(release)+' ('+release['build']+')')} — {len(release['firmwares'])} download link(s)</li>"
def catalog_build(api: Path) -> str:
    """Identify the published data, ignoring the timestamps of each run."""
    digest=hashlib.sha256()
    for path in sorted(api.glob("*/*/*.json")):
        document=json.loads(path.read_text())
        for key in ("generated_at", "generated_at_tokyo"): document.pop(key, None)
        digest.update(path.name.encode())
        digest.update(json.dumps(document, sort_keys=True, separators=(",", ":")).encode())
    return digest.hexdigest()[:12]
def generate(api: Path, output: Path):
    global CATALOG_BUILD
    if output.exists(): shutil.rmtree(output)
    shutil.copytree(ROOT/"assets", output, dirs_exist_ok=True)
    CATALOG_BUILD=catalog_build(api)
    release_meta=json.loads((api/"ios"/"release"/"all.json").read_text())
    generated=datetime.fromisoformat(release_meta["generated_at"].replace("Z", "+00:00")).astimezone(timezone.utc)
    updated=f"<p class='meta'>Catalog updated {stamp(generated)}</p>"
    combined=[]
    home=["<h1> IPSW download links</h1><p>Direct Apple CDN links, organized by OS, release channel, version, and build. IPSW files are not hosted here.</p>", "<section><h2>Update notifications</h2><p>Add this site to your iPhone Home Screen, open it as an app, then enable notifications.</p><button id='enable-notifications' type='button'>Enable update notifications</button><p id='push-status' class='meta'></p></section>", updated, "<p>{}</p>".format(link("latest/", "Latest supported downloads")+" — every operating system's supported releases on one page."), "<h2>Browse by operating system</h2>", "<ul>"]
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
    all_latest=f"<p>{link('../', '← IPSW download links')}</p><h1>Latest supported downloads</h1><p class='meta'>Every operating system's currently supported releases. Beta and RC builds are not listed here.</p>"+queue_controls("page")+"".join(combined)
    write(output/"latest"/"index.html", "Latest supported downloads", all_latest)
    (output/"version.json").write_text(json.dumps({"build": CATALOG_BUILD, "generated_at": release_meta["generated_at"], "generated_at_tokyo": release_meta.get("generated_at_tokyo")}) + "\n")
    write(output/"index.html", " IPSW download links", "".join(home)+"</ul>")
