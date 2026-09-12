"""Merge candidates with history and deterministically construct API documents."""
from __future__ import annotations
from collections import defaultdict
from copy import deepcopy
from .normalize import OS_NAMES, allowed_ipsw_url, classify, os_key_for, safe_build, safe_label, version_key
from .sources.signing import status

def normalize_candidates(candidates, settings, now):
    records, rejected = {}, []
    hosts = set(settings["allowed_cdn_hosts"])
    for row in candidates:
        device, url = row.get("device", ""), row.get("url", "")
        os_key = row.get("os_key") or os_key_for(device)
        if not os_key or not all((row.get("version"), row.get("build"), url)) or not allowed_ipsw_url(url, hosts):
            rejected.append(row); continue
        channel, label, rc = classify(str(row["version"]), str(row.get("label", "")))
        if row.get("channel") == "beta": channel = "beta"
        key = (os_key, channel, str(row["version"]), str(row["build"]), url)
        item = records.setdefault(key, {"os_key": os_key, "channel": channel, "version": str(row["version"]), "version_label": safe_label(row.get("version_label") or label), "build": safe_build(str(row["build"])), "released_at": row.get("released_at"), "prerelease": channel == "beta", "release_candidate": rc, "sources": {}, "firmwares": {}})
        item["sources"][row.get("source", "unknown")] = {"name": row.get("source", "unknown"), "checked_at": now}
        fw = item["firmwares"].setdefault(url, {"name": row.get("name") or device, "devices": set(), "url": url, "filename": url.rsplit("/", 1)[-1], "signing": {"status": status(row.get("signed")), "checked_at": now, "unsigned_since": now if row.get("signed") is False else None}})
        fw["devices"].add(device)
    result=[]
    for item in records.values():
        item["sources"] = list(item["sources"].values())
        item["firmwares"] = [{**fw, "devices": sorted(fw["devices"])} for fw in item["firmwares"].values()]
        result.append(item)
    return result, rejected

def merge(existing, observed, now):
    old = {(r["os_key"],r["channel"],r["version"],r["build"]): deepcopy(r) for r in existing}
    for record in observed:
        key=(record["os_key"],record["channel"],record["version"],record["build"])
        prior=old.get(key)
        record["first_seen_at"] = prior.get("first_seen_at", now) if prior else now
        record["last_seen_at"] = now
        if prior:
            by_url={f["url"]: f for f in prior["firmwares"]}
            for fw in record["firmwares"]:
                if fw["url"] in by_url:
                    prior_fw=by_url.pop(fw["url"])
                    if fw["signing"]["status"] == "unknown": fw["signing"] = prior_fw["signing"]
            # A source may temporarily omit old URLs: retain them as history.
            record["firmwares"].extend(by_url.values())
        old[key]=record
    return list(old.values())

def release_sort(record): return (version_key(record["version"]), record.get("released_at") or "", record["build"])
def index(records, os_key, channel, now, include_unknown_beta=True):
    relevant=[r for r in records if r["os_key"] == os_key and r["channel"] == channel]
    newest_by_device={}
    if channel == "release":
        # latest is a per-device view: retain older major versions only when a
        # device has no newer signed IPSW, rather than showing two builds for
        # the same device.
        for record in relevant:
            rank=release_sort(record)
            for firmware in record["firmwares"]:
                if firmware["signing"]["status"] != "signed": continue
                for device in firmware["devices"]:
                    if rank > newest_by_device.get(device, ()): newest_by_device[device]=rank
        relevant=[r for r in relevant if any(f["signing"]["status"] == "signed" for f in r["firmwares"])]
    elif channel == "beta" and not include_unknown_beta: relevant=[r for r in relevant if any(f["signing"]["status"] == "signed" for f in r["firmwares"])]
    if channel == "beta" and relevant:
        highest=max(version_key(r["version"]) for r in relevant); relevant=[r for r in relevant if version_key(r["version"]) == highest]
        highest_label=max((2 if r["release_candidate"] else 1, r["version_label"], r["build"], r.get("released_at") or "") for r in relevant)
        relevant=[r for r in relevant if (2 if r["release_candidate"] else 1, r["version_label"], r["build"], r.get("released_at") or "") == highest_label]
    releases=[]
    for r in sorted(relevant, key=release_sort, reverse=True):
        fws=[]
        for f in sorted(r["firmwares"], key=lambda f: f["devices"]):
            if channel == "release" and f["signing"]["status"] != "signed": continue
            devices=[d for d in f["devices"] if channel != "release" or newest_by_device.get(d) == release_sort(r)]
            if not devices: continue
            fws.append({"id": f"{os_key}-{channel}-{r['version_label']}-{r['build']}-{devices[0]}", "name": f["name"], "devices": devices, "filename": f["filename"], "url": f["url"], "signed": f["signing"]["status"] == "signed"})
        if fws: releases.append({"id": f"{os_key}-{channel}-{r['version_label']}-{r['build']}", "version": r["version"], "build": r["build"], "released_at": r.get("released_at"), "data": f"{r['version_label']}/{r['build']}.json", "firmwares": fws})
    return {"schema_version": 1, "os": OS_NAMES[os_key], "os_key": os_key, "channel": channel, "definition": "all currently signed release IPSWs" if channel == "release" else "current latest beta or release candidate IPSWs", "generated_at": now, "release_count": len(releases), "firmware_count": sum(len(r["firmwares"]) for r in releases), "releases": releases}

def all_index(records, os_key, channel, now):
    doc=index(records, os_key, channel, now, True)
    # all.json keeps unsigned history too, so rebuild from every canonical record.
    doc["releases"]=[]
    source_records=(x for x in records if x["os_key"] == os_key and x["channel"] == channel)
    for r in sorted(source_records, key=release_sort, reverse=True):
        fws=[{"id": f"{os_key}-{channel}-{r['version_label']}-{r['build']}-{f['devices'][0]}", "name": f["name"], "devices": f["devices"], "filename": f["filename"], "url": f["url"], "signed": f["signing"]["status"] == "signed"} for f in r["firmwares"]]
        doc["releases"].append({"id": f"{os_key}-{channel}-{r['version_label']}-{r['build']}", "version": r["version"], "build": r["build"], "released_at": r.get("released_at"), "signed_firmware_count": sum(f["signed"] for f in fws), "total_firmware_count": len(fws), "data": f"{r['version_label']}/{r['build']}.json", "firmwares": fws})
    doc["release_count"], doc["firmware_count"] = len(doc["releases"]), sum(len(x["firmwares"]) for x in doc["releases"])
    return doc
