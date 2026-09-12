#!/bin/bash
# Download the latest per-device IPSWs from ipsw-link-catalog.
# Requires only macOS curl and osascript (JXA); IPSWs are downloaded directly
# from Apple's CDN, never from GitHub Pages or this repository.
set -euo pipefail
export LC_ALL=C

CATALOG_BASE="${CATALOG_BASE:-https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api}"
DESTINATION_BASE="${DESTINATION_BASE:-/Volumes/IPSW}"
CHANNEL="${CHANNEL:-release}" # release or beta
MAX_CONCURRENT="${MAX_CONCURRENT:-4}"
WORK_DIR="$DESTINATION_BASE/.ipsw-catalog-work"
LOG="$WORK_DIR/download.log"
QUEUE="$WORK_DIR/queue.tsv"
LOCK_DIR="$WORK_DIR/.lock"

ENABLE_IOS="${ENABLE_IOS:-1}"
ENABLE_IPADOS="${ENABLE_IPADOS:-1}"
ENABLE_TVOS="${ENABLE_TVOS:-1}"
ENABLE_VISIONOS="${ENABLE_VISIONOS:-1}"
ENABLE_AUDIOOS="${ENABLE_AUDIOOS:-1}"
ENABLE_MACOS="${ENABLE_MACOS:-1}"

declare -A DESTINATIONS=(
  [ios]="iPhone Software Updates"
  [ipados]="iPad Software Updates"
  [tvos]="Apple TV Software Updates"
  [visionos]="Apple Vision Pro Software Updates"
  [audioos]="HomePod Software Updates"
  [macos]="Mac Software Updates"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG" >&2; }
die() { log "FATAL: $*"; exit 1; }

[[ "$CHANNEL" == release || "$CHANNEL" == beta ]] || die "CHANNEL must be release or beta"
[[ -d "$DESTINATION_BASE" ]] || die "Destination does not exist: $DESTINATION_BASE"
command -v curl >/dev/null || die "curl is required"
command -v osascript >/dev/null || die "osascript is required"
mkdir -p "$WORK_DIR"
touch "$LOG"
mkdir "$LOCK_DIR" 2>/dev/null || die "Already running: $LOCK_DIR"
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM HUP
: > "$QUEUE"

# Emit: version, build, model name, identifiers, filename, Apple URL, signed.
parse_latest() {
  osascript -l JavaScript - "$1" <<'JXA'
ObjC.import('Foundation');
const path=ObjC.unwrap($.NSProcessInfo.processInfo.arguments.lastObject);
const text=$.NSString.stringWithContentsOfFileEncodingError(path,$.NSUTF8StringEncoding,null);
if (!text) $.exit(2);
let doc; try { doc=JSON.parse(ObjC.unwrap(text)); } catch (_) { $.exit(3); }
for (const release of (doc.releases || [])) for (const fw of (release.firmwares || [])) {
  const clean=v=>String(v ?? '').replace(/[\t\r\n]/g,' ');
  console.log([clean(release.version),clean(release.build),clean(fw.name),clean((fw.devices||[]).join(',')),clean(fw.filename),clean(fw.url),fw.signed?'true':'false'].join('\t'));
}
JXA
}

collect_os() {
  local os="$1" enabled="$2" json="$WORK_DIR/$os-$CHANNEL.json" tmp="$json.tmp"
  [[ "$enabled" == 1 ]] || return 0
  log "Checking $os/$CHANNEL latest"
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 --max-time 90 \
    "$CATALOG_BASE/$os/$CHANNEL/latest.json" -o "$tmp" || { rm -f "$tmp"; log "WARNING: catalog unavailable for $os"; return 0; }
  mv "$tmp" "$json"
  while IFS=$'\t' read -r version build name devices filename url signed; do
    [[ "$signed" == true || "$CHANNEL" == beta ]] || continue
    [[ "$url" =~ ^https://(updates\.cdn-apple\.com|secure-appldnld\.apple\.com|appldnld\.apple\.com)/.*\.ipsw$ ]] || { log "WARNING: rejected URL for $filename"; continue; }
    [[ -n "$filename" && -n "$version" && -n "$build" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$os" "$version" "$build" "$name" "$devices" "$filename" "$url" >> "$QUEUE"
  done < <(parse_latest "$json")
}

collect_os ios "$ENABLE_IOS"
collect_os ipados "$ENABLE_IPADOS"
collect_os tvos "$ENABLE_TVOS"
collect_os visionos "$ENABLE_VISIONOS"
collect_os audioos "$ENABLE_AUDIOOS"
collect_os macos "$ENABLE_MACOS"
[[ -s "$QUEUE" ]] || die "No downloadable IPSWs in the selected latest catalogs"

download_one() {
  local os="$1" version="$2" build="$3" name="$4" devices="$5" filename="$6" url="$7"
  local directory="$DESTINATION_BASE/${DESTINATIONS[$os]}" destination="$DESTINATION_BASE/${DESTINATIONS[$os]}/$filename" partial
  mkdir -p "$directory"; partial="$destination.part"
  if [[ -f "$destination" ]]; then log "SKIP existing: $filename"; return; fi
  log "DOWNLOAD: $os $version ($build) — $name [$devices]"
  curl --fail --show-error --location --retry 3 --retry-delay 3 --continue-at - --output "$partial" "$url" && mv "$partial" "$destination"
}

while IFS=$'\t' read -r os version build name devices filename url; do
  # macOS ships Bash 3.2, which does not support `wait -n`.
  while [[ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$MAX_CONCURRENT" ]]; do sleep 1; done
  download_one "$os" "$version" "$build" "$name" "$devices" "$filename" "$url" &
done < <(sort -u -t $'\t' -k6,6 "$QUEUE")
wait
log "Completed latest $CHANNEL download check"
