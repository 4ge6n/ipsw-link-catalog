"""Create a human-readable static site from the canonical API documents."""
from __future__ import annotations
import html
import json
import shutil
from pathlib import Path
from .normalize import OS_NAMES, OS_ORDER

STYLE = "body{font-family:system-ui,sans-serif;max-width:1100px;margin:2rem auto;padding:0 1rem;color:#1d1d1f}a{color:#06c}table{border-collapse:collapse;width:100%}th,td{padding:.65rem;border-bottom:1px solid #ddd;text-align:left}code{font-size:.9em}.meta{color:#666}"
def write(path: Path, title: str, body: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"<!doctype html><html lang='en'><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>{html.escape(title)}</title><style>{STYLE}</style><body>{body}</body></html>\n")
def link(href: str, text: str) -> str: return f"<a href='{html.escape(href, quote=True)}'>{html.escape(text)}</a>"
def firmware_table(release: dict) -> str:
    rows=[]
    for fw in release["firmwares"]:
        devices="<br>".join(html.escape(x) for x in fw["devices"])
        rows.append(f"<tr><td>{html.escape(fw['name'])}</td><td><code>{devices}</code></td><td>{link(fw['url'], fw['filename'])}</td><td>{'Signed' if fw['signed'] else 'Not signed'}</td></tr>")
    return "<table><thead><tr><th>Device</th><th>Identifiers</th><th>Apple download</th><th>Status</th></tr></thead><tbody>" + "".join(rows) + "</tbody></table>"
def generate(api: Path, output: Path):
    if output.exists(): shutil.rmtree(output)
    release_meta=json.loads((api/"ios"/"release"/"all.json").read_text())
    updated=f"<p class='meta'>Catalog updated: UTC {html.escape(release_meta['generated_at'])} · Asia/Tokyo {html.escape(release_meta.get('generated_at_tokyo', 'unknown'))}</p>"
    home=["<h1>Apple IPSW download links</h1><p>Direct Apple CDN links, organized by OS, release channel, version, and build. IPSW files are not hosted here.</p>", updated, "<ul>"]
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
                channel_page.append(f"<li>{link(href, release['version']+' ('+release['build']+')')} — {len(release['firmwares'])} download link(s)</li>")
                page=f"<p>{link('../../', '← '+channel.title()+' list')}</p><h1>{OS_NAMES[os_key]} {channel.title()} {html.escape(release['version'])} ({html.escape(release['build'])})</h1><p class='meta'>Released: {html.escape(release.get('released_at') or 'unknown')}</p>"+firmware_table(release)
                write(output/os_key/channel/release["data"].removesuffix(".json")/"index.html", f"{OS_NAMES[os_key]} {release['version']} ({release['build']})", page)
            if channel == "release":
                latest=json.loads((api/os_key/channel/"latest.json").read_text())
                latest_body=f"<p>{link('../', '← '+channel.title()+' list')}</p><h1>Latest {OS_NAMES[os_key]} {channel.title()} downloads</h1>"+"".join(f"<h2>{html.escape(r['version'])} ({html.escape(r['build'])})</h2>"+firmware_table(r) for r in latest["releases"])
                write(output/os_key/channel/"latest"/"index.html", f"Latest {OS_NAMES[os_key]} {channel}", latest_body or "<p>No downloads available.</p>")
            write(output/os_key/channel/"index.html", f"{OS_NAMES[os_key]} {channel}", "".join(channel_page)+"</ul>")
    write(output/"index.html", "Apple IPSW download links", "".join(home)+"</ul>")
