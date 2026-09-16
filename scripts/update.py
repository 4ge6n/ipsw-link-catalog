"""Atomically fetch, merge, generate, and validate the IPSW JSON catalog."""
from __future__ import annotations
import argparse, json, os, re, shutil, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
from pathlib import Path
from urllib.parse import urlparse
sys.path.insert(0, str(Path(__file__).parent.parent))
from scripts.generate_readme import content, replace
from scripts.generate_site import generate as generate_site
from scripts.normalize import OS_ORDER, safe_build, version_key
from scripts.organize import all_index, index, merge, normalize_candidates
from scripts.sources import apple, beta, release, tss
from scripts.validate import validate_api

ROOT=Path(__file__).parent.parent
def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True); path.write_text(json.dumps(value, ensure_ascii=False, indent=2)+"\n")
def existing_records(api):
    records=[]
    for fixed in api.glob("*/*/*/*.json"):
        try:
            record=json.loads(fixed.read_text())
            # Earlier beta documents used labels such as "27.0 RC" as their
            # version. Fold those into the numeric canonical version.
            match=re.search(r"[0-9]+(?:\.[0-9]+)*", str(record.get("version", "")))
            if match: record["version"]=match.group(0)
            # Repair catalogs generated before the source track was retained.
            # iPadOS began at 13; older iPad beta records are iOS releases.
            if record.get("os_key") == "ipados" and record.get("channel") == "beta" and match and int(match.group(0).split(".", 1)[0]) < 13:
                record["os_key"]="ios"
            record["build"]=safe_build(record["build"])
            records.append(record)
        except json.JSONDecodeError: pass
    return records
DEVICE_NAMES=ROOT/"config"/"device-names.json"
def known_device_names(records) -> dict[str, str]:
    """Marketing names this catalog already knows, so a new build keeps them.

    Apple identifies hardware only as iPhone18,5 and publishes no mapping to
    the name people use, so the mapping is kept here. It is seeded from the
    catalog's own history and learned once from whichever source first names
    a new device, after which nothing needs to be asked again.
    """
    names=json.loads(DEVICE_NAMES.read_text()) if DEVICE_NAMES.exists() else {}
    for record in records:
        for firmware in record.get("firmwares", []):
            name=firmware.get("name")
            devices=firmware.get("devices") or []
            if not name or name in devices: continue
            for device in devices: names.setdefault(device, name)
    return names
def learn_device_names(records, names) -> list[str]:
    """Persist any name a source supplied for a device we had not named."""
    learned={}
    for record in records:
        for firmware in record.get("firmwares", []):
            name=firmware.get("name")
            devices=firmware.get("devices") or []
            if not name or name in devices: continue
            for device in devices:
                if device not in names: learned[device]=name
    if learned:
        DEVICE_NAMES.parent.mkdir(parents=True, exist_ok=True)
        DEVICE_NAMES.write_text(json.dumps(dict(sorted({**names, **learned}.items())), ensure_ascii=False, indent=2)+"\n")
    return sorted(learned)
def apply_device_names(records, names) -> None:
    for record in records:
        for firmware in record.get("firmwares", []):
            if firmware.get("name") not in (firmware.get("devices") or []): continue
            for device in firmware["devices"]:
                if device in names:
                    firmware["name"]=names[device]
                    break
def verify_signing(records, apple_urls, settings, now, limit=12):
    """Confirm with Apple whether builds it no longer lists are still signed.

    Apple's catalog only names the build it currently restores for each
    device, so anything else it says nothing about. Signing is a property of
    the build, so one answer settles every file in it.
    """
    pending={}
    for record in records:
        # A Mac restores through a different personalization flow, and the
        # mobile-shaped request is refused for every build including ones
        # Apple shipped today, so its signing is left to the catalog.
        if record["channel"] != "release" or record["os_key"] == "macos": continue
        stale=[f for f in record["firmwares"]
               if f["signing"]["status"] == "signed" and f["url"] not in apple_urls]
        if stale: pending[(record["os_key"], record["version"], record["build"])]=(record, stale)
    newest=sorted(pending, key=lambda key: version_key(key[1]), reverse=True)[:limit]
    def probe(key):
        record, stale = pending[key]
        for firmware in stale:
            try: verdict=tss.signing_status(firmware["url"], settings["request_timeout_seconds"])
            except Exception: continue
            if verdict is not None: return key, verdict
        return key, None
    checked=0
    with ThreadPoolExecutor(max_workers=4) as pool:
        for key, verdict in pool.map(probe, newest):
            if verdict is None: continue
            checked += 1
            record, stale = pending[key]
            for firmware in stale:
                firmware["signing"]["status"]="signed" if verdict else "unsigned"
                firmware["signing"]["checked_at"]=now
                if not verdict and not firmware["signing"].get("unsigned_since"):
                    firmware["signing"]["unsigned_since"]=now
    return {"builds_probed": len(newest), "builds_answered": checked}
def generate(records, api, settings, now, now_tokyo):
    indexes={}
    for os_key in OS_ORDER:
        for channel in ("release", "beta"):
            folder=api/os_key/channel
            all_doc=all_index(records, os_key, channel, now)
            all_doc["generated_at_tokyo"] = now_tokyo
            dump(folder/"all.json", all_doc)
            # Beta/RC does not have a stable meaning of “latest”: candidates
            # can coexist across branches, devices, and seed tracks.  Publish
            # only all.json for beta so consumers do not mistake it for a
            # release-channel selection.
            if channel == "release":
                latest=index(records, os_key, channel, now, settings["include_unknown_beta_signing"])
                latest["generated_at_tokyo"] = now_tokyo
                dump(folder/"latest.json", latest)
                indexes[(os_key,channel)]=latest
            else:
                indexes[(os_key,channel)]=all_doc
    for r in records: dump(api/r["os_key"]/r["channel"]/r["version_label"]/(r["build"]+".json"), r)
    return indexes
def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--input", type=Path, help="normalized candidate JSON fixture; avoids network")
    parser.add_argument("--bootstrap-empty", action="store_true", help="generate empty indexes only")
    args=parser.parse_args(); settings=json.loads((ROOT/"config.json").read_text())
    current_time=datetime.now(timezone.utc).replace(microsecond=0)
    now=current_time.isoformat().replace("+00:00","Z")
    now_tokyo=current_time.astimezone(ZoneInfo("Asia/Tokyo")).isoformat()
    old=existing_records(ROOT/"api")
    if args.bootstrap_empty: candidates=[]
    elif args.input: candidates=json.loads(args.input.read_text())
    else:
        candidates=[]; failures=[]
        # Apple first: where it and a third party disagree, Apple wins.
        for source in (apple.fetch, release.fetch, beta.fetch):
            try: candidates.extend(source(settings["request_timeout_seconds"]))
            except Exception as exc: failures.append(str(exc))
        if not candidates: raise SystemExit("all information sources failed or returned no data; catalog preserved")
    observed, rejected=normalize_candidates(candidates, settings, now)
    if not args.input and not args.bootstrap_empty:
        # Apple's restore catalog carries no dates. A third party records when
        # it noticed a build, which for a fresh release is well after Apple
        # shipped it, so Apple's own announcement wins wherever it reaches.
        try: announced=apple.release_dates(settings["request_timeout_seconds"])
        except Exception: announced={}
        dated=0
        for record in observed:
            stamp=announced.get((record["version"], record["build"]))
            if stamp and record.get("released_at") != stamp: record["released_at"]=stamp; dated+=1
        if dated: print(json.dumps({"release_dates_from_apple": dated}))
    device_names=known_device_names(old)
    learned=learn_device_names(observed, device_names)
    device_names.update({device: name for record in observed for firmware in record["firmwares"]
                         for device in [d for d in firmware["devices"] if d in learned]
                         for name in [firmware["name"]]})
    apply_device_names(observed, device_names)
    unnamed=sorted({device for record in observed for firmware in record["firmwares"]
                    for device in firmware["devices"] if device not in device_names})
    if unnamed and not args.input:
        # Apple names no hardware, so a device nobody has named yet is looked
        # up once and written down; later runs read it from config.
        try: catalogue=release.device_names(settings["request_timeout_seconds"])
        except Exception: catalogue={}
        found={device: catalogue[device] for device in unnamed if device in catalogue}
        if found:
            device_names.update(found)
            DEVICE_NAMES.write_text(json.dumps(dict(sorted(device_names.items())), ensure_ascii=False, indent=2)+"\n")
            learned=sorted(set(learned) | set(found))
            apply_device_names(observed, device_names)
            unnamed=[device for device in unnamed if device not in found]
    if learned or unnamed: print(json.dumps({"device_names_learned": learned, "devices_still_unnamed": unnamed}))
    # Public sources may include OTA/asset rows alongside IPSWs. They are
    # deliberately ignored; a syntactically valid IPSW on an unknown host is a
    # supply-chain alert and must stop publication.
    unknown_hosts=sorted({urlparse(row.get("url", "")).hostname for row in rejected if row.get("url", "").startswith("https://") and row.get("url", "").lower().split("?", 1)[0].endswith(".ipsw") and urlparse(row["url"]).hostname not in settings["allowed_cdn_hosts"]})
    if unknown_hosts: raise SystemExit("unknown IPSW CDN hosts: " + ", ".join(unknown_hosts))
    if rejected: print(json.dumps({"ignored_non_ipsw_or_incomplete_candidates": len(rejected)}))
    old_records={(r["os_key"], r["channel"], r["version"], r["build"]) for r in old}
    old_urls={fw["url"] for record in old for fw in record.get("firmwares", [])}
    observed_records={(r["os_key"], r["channel"], r["version"], r["build"]) for r in observed}
    observed_urls={fw["url"] for record in observed for fw in record.get("firmwares", [])}
    records=merge(old, observed, now)
    if not args.input and not args.bootstrap_empty:
        apple_urls={row["url"] for row in candidates if row.get("source") == "apple"}
        print(json.dumps(verify_signing(records, apple_urls, settings, now)))
    with tempfile.TemporaryDirectory(prefix="ipsw-catalog-") as tmp:
        stage=Path(tmp)/"api"; site_stage=Path(tmp)/"site"; indexes=generate(records, stage, settings, now, now_tokyo)
        errors=validate_api(stage, set(settings["allowed_cdn_hosts"]))
        if errors: raise SystemExit("validation failed:\n"+"\n".join(errors))
        generate_site(stage, site_stage)
        shutil.rmtree(ROOT/"api", ignore_errors=True); shutil.copytree(stage, ROOT/"api")
        shutil.rmtree(ROOT/"site", ignore_errors=True); shutil.copytree(site_stage, ROOT/"site")
    readme=ROOT/"README.md"; current=readme.read_text() if readme.exists() else "# IPSW Link Catalog\n\nStable JSON indexes of Apple restore images.\n"
    dump_owner=os.getenv("GITHUB_REPOSITORY", "4ge6n/ipsw-link-catalog")
    readme.write_text(replace(current, content(indexes, now, now_tokyo, dump_owner, settings["default_branch"])))
    # Named rather than counted, so a notification can say what turned up
    # instead of that something did. Capped: a first run sees everything.
    new_builds=[{"os":os_key, "channel":channel, "version":version, "build":build} for os_key, channel, version, build in sorted(observed_records-old_records)][:12]
    print(json.dumps({"candidates":len(candidates), "records":len(records), "rejected":len(rejected), "new_records":len(observed_records-old_records), "new_firmware_urls":len(observed_urls-old_urls), "new_builds":new_builds}))
if __name__ == "__main__": main()
