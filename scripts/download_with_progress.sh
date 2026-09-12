#!/bin/bash
# Standalone latest IPSW downloader with six visible curl progress bars.
# It does not source or execute another .sh file.
set -euo pipefail
export LC_ALL=C

CATALOG_BASE="${CATALOG_BASE:-https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api}"
DESTINATION_BASE="${DESTINATION_BASE:-/Volumes/IPSW}"
MAX_CONCURRENT="${MAX_CONCURRENT:-6}"
MAX_RETRY="${MAX_RETRY:-3}"
DRY_RUN="${DRY_RUN:-0}" # Only for validation; normal execution downloads.
WORK_DIR="$DESTINATION_BASE/.ipsw-progress-work"
LOG="$WORK_DIR/download.log"
QUEUE="$WORK_DIR/queue.tsv"
RESULTS="$WORK_DIR/results.$$"
LOCK="$WORK_DIR/.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG" >&2; }
die() { log "FATAL: $*"; exit 1; }

[[ "$MAX_CONCURRENT" =~ ^[1-9][0-9]*$ ]] || die "MAX_CONCURRENT must be a positive integer"
[[ "$MAX_RETRY" =~ ^[1-9][0-9]*$ ]] || die "MAX_RETRY must be a positive integer"
[[ -d "$DESTINATION_BASE" ]] || die "Destination does not exist: $DESTINATION_BASE"
for command in curl osascript unzip mktemp; do command -v "$command" >/dev/null || die "$command is required"; done
mkdir -p "$WORK_DIR" "$RESULTS"; touch "$LOG"; : > "$QUEUE"
if [[ -d "$LOCK" ]]; then die "Already running: $LOCK"; fi
mkdir "$LOCK" || die "Cannot create lock"
cleanup() { rm -rf "$LOCK" "$RESULTS"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# Output: version<TAB>build<TAB>name<TAB>devices<TAB>filename<TAB>url<TAB>signed
parse_latest() {
  osascript -l JavaScript - "$1" <<'JXA'
ObjC.import('Foundation');
const path=ObjC.unwrap($.NSProcessInfo.processInfo.arguments.lastObject);
const text=$.NSString.stringWithContentsOfFileEncodingError(path,$.NSUTF8StringEncoding,null);
if(!text) $.exit(2); let doc; try { doc=JSON.parse(ObjC.unwrap(text)); } catch (_) { $.exit(3); }
const out=s=>$.NSFileHandle.fileHandleWithStandardOutput.writeData($.NSString.stringWithString(s+'\n').dataUsingEncoding($.NSUTF8StringEncoding));
const clean=v=>String(v??'').replace(/[\t\r\n]/g,' ');
for(const release of (doc.releases||[])) for(const fw of (release.firmwares||[])) out([clean(release.version),clean(release.build),clean(fw.name),clean((fw.devices||[]).join(',')),clean(fw.filename),clean(fw.url),fw.signed?'true':'false'].join('\t'));
JXA
}

collect() {
  local os="$1" json temp
  json="$WORK_DIR/$os.json"; temp="$json.tmp"
  log "Checking $os/release latest"
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 --max-time 90 \
    --user-agent "ipsw-link-catalog-progress/1.0" "$CATALOG_BASE/$os/release/latest.json" -o "$temp" || die "Catalog unavailable: $os"
  mv "$temp" "$json"
  parse_latest "$json" | while IFS=$'\t' read -r version build name devices filename url signed; do
    [[ "$signed" == true ]] || continue
    [[ "$url" =~ ^https://(updates\.cdn-apple\.com|secure-appldnld\.apple\.com|appldnld\.apple\.com)/.*\.ipsw$ ]] || { log "Rejected URL: $filename"; continue; }
    case "$os:$filename" in
      ios:iPhone*_Restore.ipsw) folder='iPhone Software Updates' ;;
      ios:iPod*_Restore.ipsw) folder='iPod Software Updates' ;;
      ipados:iPad*_Restore.ipsw) folder='iPad Software Updates' ;;
      *) continue ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$os" "$version" "$build" "$name" "$devices" "$filename" "$url" "$folder" >> "$QUEUE"
  done
}

collect ios
collect ipados
[[ -s "$QUEUE" ]] || die "No downloadable latest IPSWs"

download_one() {
  local os="$1" version="$2" build="$3" name="$4" devices="$5" filename="$6" url="$7" folder="$8"
  local directory="$DESTINATION_BASE/$folder" destination partial attempt=1
  destination="$directory/$filename"; partial="$destination.part"; mkdir -p "$directory"
  if [[ "$DRY_RUN" == 1 ]]; then
    if curl --fail --silent --show-error --location --head --connect-timeout 20 --max-time 90 "$url" >/dev/null; then
      log "DRY RUN OK: $os $version ($build) — $filename"
      return 0
    fi
    log "DRY RUN FAILED: $filename"; return 1
  fi
  if [[ -f "$destination" ]] && unzip -tqq "$destination" >/dev/null 2>&1; then log "SKIP verified: $filename"; return 0; fi
  log "DOWNLOAD: $os $version ($build) — $name [$devices]"
  while [[ "$attempt" -le "$MAX_RETRY" ]]; do
    log "TRY $attempt/$MAX_RETRY: $filename"
    if curl --fail --show-error --location --progress-bar --continue-at - --retry 2 --retry-delay 3 \
      --connect-timeout 30 --speed-limit 1024 --speed-time 120 \
      --user-agent "ipsw-link-catalog-progress/1.0" --output "$partial" "$url" \
      && unzip -tqq "$partial" >/dev/null 2>&1; then
      mv "$partial" "$destination"; log "DOWNLOAD OK: $filename"; return 0
    fi
    log "RETRYING: $filename"; rm -f "$partial"; attempt=$((attempt + 1)); sleep 3
  done
  log "DOWNLOAD FAILED: $filename"; return 1
}

pids=""; failed=0
while IFS=$'\t' read -r os version build name devices filename url folder; do
  while [[ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$MAX_CONCURRENT" ]]; do sleep 1; done
  ( download_one "$os" "$version" "$build" "$name" "$devices" "$filename" "$url" "$folder" ) &
  pids="$pids $!"
done < <(sort -u -t $'\t' -k6,6 "$QUEUE")
for pid in $pids; do wait "$pid" || failed=1; done
log "Completed progress download: failed=$failed"
exit "$failed"
