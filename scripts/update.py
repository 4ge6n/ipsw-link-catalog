"""Atomically fetch, merge, generate, and validate the IPSW JSON catalog."""
from __future__ import annotations
import argparse, json, os, shutil, sys, tempfile
from datetime import datetime, timezone
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))
from scripts.generate_readme import content, replace
from scripts.normalize import OS_ORDER, safe_build
from scripts.organize import all_index, index, merge, normalize_candidates
from scripts.sources import beta, release
from scripts.validate import validate_api

ROOT=Path(__file__).parent.parent
def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True); path.write_text(json.dumps(value, ensure_ascii=False, indent=2)+"\n")
def existing_records(api):
    records=[]
    for fixed in api.glob("*/*/*/*.json"):
        try:
            record=json.loads(fixed.read_text())
            record["build"]=safe_build(record["build"])
            records.append(record)
        except json.JSONDecodeError: pass
    return records
def generate(records, api, settings, now):
    indexes={}
    for os_key in OS_ORDER:
        for channel in ("release", "beta"):
            folder=api/os_key/channel
            latest=index(records, os_key, channel, now, settings["include_unknown_beta_signing"])
            all_doc=all_index(records, os_key, channel, now)
            dump(folder/"latest.json", latest); dump(folder/"all.json", all_doc); indexes[(os_key,channel)]=latest
    for r in records: dump(api/r["os_key"]/r["channel"]/r["version_label"]/(r["build"]+".json"), r)
    return indexes
def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--input", type=Path, help="normalized candidate JSON fixture; avoids network")
    parser.add_argument("--bootstrap-empty", action="store_true", help="generate empty indexes only")
    args=parser.parse_args(); settings=json.loads((ROOT/"config.json").read_text()); now=datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z")
    old=existing_records(ROOT/"api")
    if args.bootstrap_empty: candidates=[]
    elif args.input: candidates=json.loads(args.input.read_text())
    else:
        candidates=[]; failures=[]
        for source in (release.fetch, beta.fetch):
            try: candidates.extend(source(settings["request_timeout_seconds"]))
            except Exception as exc: failures.append(str(exc))
        if not candidates: raise SystemExit("all information sources failed or returned no data; catalog preserved")
    observed, rejected=normalize_candidates(candidates, settings, now)
    # Public sources may include OTA/asset rows alongside IPSWs. They are
    # deliberately ignored; a syntactically valid IPSW on an unknown host is a
    # supply-chain alert and must stop publication.
    unknown_hosts=sorted({row.get("url", "").split("/")[2] for row in rejected if row.get("url", "").startswith("https://") and row.get("url", "").lower().split("?", 1)[0].endswith(".ipsw")})
    if unknown_hosts: raise SystemExit("unknown IPSW CDN hosts: " + ", ".join(unknown_hosts))
    if rejected: print(json.dumps({"ignored_non_ipsw_or_incomplete_candidates": len(rejected)}))
    records=merge(old, observed, now)
    with tempfile.TemporaryDirectory(prefix="ipsw-catalog-") as tmp:
        stage=Path(tmp)/"api"; indexes=generate(records, stage, settings, now)
        errors=validate_api(stage, set(settings["allowed_cdn_hosts"]))
        if errors: raise SystemExit("validation failed:\n"+"\n".join(errors))
        shutil.rmtree(ROOT/"api", ignore_errors=True); shutil.copytree(stage, ROOT/"api")
    readme=ROOT/"README.md"; current=readme.read_text() if readme.exists() else "# IPSW Link Catalog\n\nStable JSON indexes of Apple restore images.\n"
    dump_owner=os.getenv("GITHUB_REPOSITORY", "4ge6n/ipsw-link-catalog")
    readme.write_text(replace(current, content(indexes, now, dump_owner, settings["default_branch"])))
    print(json.dumps({"candidates":len(candidates), "records":len(records), "rejected":len(rejected)}))
if __name__ == "__main__": main()
