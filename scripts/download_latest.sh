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
DRY_RUN="${DRY_RUN:-0}" # 1 = validate and list downloads without saving IPSWs
MAX_RETRY="${MAX_RETRY:-3}"
VERIFY_ALL="${VERIFY_ALL:-1}"
# Set to 1 only when old IPSWs in the same device-family and major version
# should be removed after a verified replacement has been downloaded.
REMOVE_OLDER="${REMOVE_OLDER:-0}"
WORK_DIR="$DESTINATION_BASE/.ipsw-catalog-work"
LOG="$WORK_DIR/download.log"
QUEUE="$WORK_DIR/queue.tsv"
LOCK_DIR="$WORK_DIR/.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"
MANIFEST="$WORK_DIR/manifest.tsv"
SUCCESSFUL="$WORK_DIR/successful.tsv"
FAILED="$WORK_DIR/failed.tsv"
RESULTS_DIR="$WORK_DIR/results"

# This downloader intentionally handles only iPhone and iPad restores.
ENABLE_IOS="${ENABLE_IOS:-1}"
ENABLE_IPADOS="${ENABLE_IPADOS:-1}"

destination_for_os() {
  case "$1" in
    ios) printf '%s\n' 'iPhone Software Updates' ;;
    ipados) printf '%s\n' 'iPad Software Updates' ;;
    *) return 1 ;;
  esac
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG" >&2; }
die() { log "FATAL: $*"; exit 1; }

get_file_size() {
  [[ -f "$1" ]] || return 1
  wc -c < "$1" | tr -d ' '
}

verify_file_size() {
  local actual
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || return 1
  actual=$(get_file_size "$1") || return 1
  [[ "$actual" == "$2" ]]
}

# The catalog deliberately does not need to store a duplicate file-size index.
# Resolve Content-Length from Apple's CDN just before downloading and retain it
# in the local manifest for future integrity checks.
get_remote_size() {
  local url="$1" size
  size=$(curl --fail --silent --show-error --location --head \
    --retry 2 --connect-timeout 20 --max-time 90 "$url" 2>/dev/null \
    | awk 'BEGIN{IGNORECASE=1} /^content-length:[[:space:]]*[0-9]+/ {v=$2} END {gsub("\\r", "", v); print v}') || return 1
  [[ "$size" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$size"
}

manifest_get_size() {
  local os="$1" version="$2" build="$3" filename="$4"
  awk -F $'\t' -v o="$os" -v v="$version" -v b="$build" -v f="$filename" \
    '$1==o && $2==v && $3==b && $7==f && $5 ~ /^[1-9][0-9]*$/ {print $5; exit}' "$MANIFEST"
}

record_result() {
  local kind="$1" os="$2" version="$3" build="$4" devices="$5" size="$6" url="$7" filename="$8" result
  result=$(mktemp "$RESULTS_DIR/$kind.XXXXXX.tsv") || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$os" "$version" "$build" "$devices" "$size" "$url" "$filename" \
    > "$result"
}

version_less_than() {
  awk -v older="$1" -v newer="$2" '
    BEGIN {
      no=split(older,o,"."); nn=split(newer,n,"."); max=(no>nn?no:nn)
      for (i=1; i<=max; i++) {
        a=(i<=no ? o[i]+0 : 0); b=(i<=nn ? n[i]+0 : 0)
        if (a < b) exit 0
        if (a > b) exit 1
      }
      exit 1
    }'
}

firmware_family() {
  printf '%s\n' "$1" | sed -n 's/^\(.*\)_[0-9][0-9.]*_[0-9][0-9]*[A-Za-z][A-Za-z]*[0-9][A-Za-z0-9]*_Restore\.ipsw$/\1/p'
}

firmware_version() {
  printf '%s\n' "$1" | sed -n 's/^.*_\([0-9][0-9.]*\)_[0-9][0-9]*[A-Za-z][A-Za-z]*[0-9][A-Za-z0-9]*_Restore\.ipsw$/\1/p'
}

[[ "$CHANNEL" == release || "$CHANNEL" == beta ]] || die "CHANNEL must be release or beta"
[[ "$MAX_CONCURRENT" =~ ^[1-9][0-9]*$ ]] || die "MAX_CONCURRENT must be a positive integer"
[[ "$MAX_RETRY" =~ ^[1-9][0-9]*$ ]] || die "MAX_RETRY must be a positive integer"
[[ -d "$DESTINATION_BASE" ]] || die "Destination does not exist: $DESTINATION_BASE"
command -v curl >/dev/null || die "curl is required"
command -v osascript >/dev/null || die "osascript is required"
command -v mktemp >/dev/null || die "mktemp is required"
mkdir -p "$WORK_DIR"
touch "$LOG"
if [[ -d "$LOCK_DIR" ]]; then
  old_pid=""
  [[ -f "$LOCK_PID_FILE" ]] && old_pid=$(cat "$LOCK_PID_FILE" 2>/dev/null || true)
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    die "Already running: PID=$old_pid"
  fi
  [[ "$old_pid" =~ ^[0-9]+$ ]] || die "Lock cannot be validated: $LOCK_DIR"
  log "Removing stale lock: PID=$old_pid"
  rm -rf "$LOCK_DIR"
fi
mkdir "$LOCK_DIR" || die "Cannot create lock: $LOCK_DIR"
printf '%s\n' "$$" > "$LOCK_PID_FILE"
cleanup_lock() {
  [[ -f "$LOCK_PID_FILE" ]] || return 0
  [[ "$(cat "$LOCK_PID_FILE" 2>/dev/null || true)" == "$$" ]] && rm -rf "$LOCK_DIR"
}
trap cleanup_lock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
: > "$QUEUE"
: > "$SUCCESSFUL"
: > "$FAILED"
[[ -f "$MANIFEST" ]] || : > "$MANIFEST"
mkdir -p "$RESULTS_DIR"

# Emit: version, build, model name, identifiers, filename, Apple URL, signed.
parse_latest() {
  osascript -l JavaScript - "$1" <<'JXA'
ObjC.import('Foundation');
const path=ObjC.unwrap($.NSProcessInfo.processInfo.arguments.lastObject);
const text=$.NSString.stringWithContentsOfFileEncodingError(path,$.NSUTF8StringEncoding,null);
if (!text) $.exit(2);
let doc; try { doc=JSON.parse(ObjC.unwrap(text)); } catch (_) { $.exit(3); }
function output(line) {
  const data=$.NSString.stringWithString(line+'\n').dataUsingEncoding($.NSUTF8StringEncoding);
  $.NSFileHandle.fileHandleWithStandardOutput.writeData(data);
}
for (const release of (doc.releases || [])) for (const fw of (release.firmwares || [])) {
  const clean=v=>String(v ?? '').replace(/[\t\r\n]/g,' ');
  output([clean(release.version),clean(release.build),clean(fw.name),clean((fw.devices||[]).join(',')),clean(fw.filename),clean(fw.url),fw.signed?'true':'false'].join('\t'));
}
JXA
}

collect_os() {
  local os enabled json tmp
  os="$1"; enabled="$2"; json="$WORK_DIR/$os-$CHANNEL.json"; tmp="$json.tmp"
  [[ "$enabled" == 1 ]] || return 0
  log "Checking $os/$CHANNEL latest"
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 --max-time 90 \
    "$CATALOG_BASE/$os/$CHANNEL/latest.json" -o "$tmp" || { rm -f "$tmp"; log "WARNING: catalog unavailable for $os"; return 0; }
  mv "$tmp" "$json"
  while IFS=$'\t' read -r version build name devices filename url signed; do
    [[ "$signed" == true || "$CHANNEL" == beta ]] || continue
    [[ "$url" =~ ^https://(updates\.cdn-apple\.com|secure-appldnld\.apple\.com|appldnld\.apple\.com)/.*\.ipsw$ ]] || { log "WARNING: rejected URL for $filename"; continue; }
    case "$os:$filename" in
      ios:iPhone*_Restore.ipsw|ipados:iPad*_Restore.ipsw) ;;
      *) continue ;;
    esac
    [[ -n "$filename" && -n "$version" && -n "$build" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$os" "$version" "$build" "$name" "$devices" "$filename" "$url" >> "$QUEUE"
  done < <(parse_latest "$json")
}

collect_os ios "$ENABLE_IOS"
collect_os ipados "$ENABLE_IPADOS"
[[ -s "$QUEUE" ]] || die "No downloadable IPSWs in the selected latest catalogs"

download_one() {
  local os="$1" version="$2" build="$3" name="$4" devices="$5" filename="$6" url="$7"
  local folder directory destination partial expected try actual
  folder=$(destination_for_os "$os") || return 1
  directory="$DESTINATION_BASE/$folder"; destination="$directory/$filename"
  if [[ "$DRY_RUN" == 1 ]]; then
    log "DRY RUN: $os $version ($build) — $filename"
    log "  $url"
    return 0
  fi
  mkdir -p "$directory"; partial="$destination.part"
  expected=$(manifest_get_size "$os" "$version" "$build" "$filename")
  if [[ ! "$expected" =~ ^[1-9][0-9]*$ ]]; then
    log "HEAD size: $filename"
    expected=$(get_remote_size "$url" 2>/dev/null || true)
  fi
  if [[ ! "$expected" =~ ^[1-9][0-9]*$ ]]; then
    log "FAILED: cannot determine expected size: $filename"
    record_result failed "$os" "$version" "$build" "$devices" 0 "$url" "$filename"
    return 0
  fi
  if [[ -f "$destination" ]] && verify_file_size "$destination" "$expected"; then
    log "SKIP verified existing: $filename"
    return 0
  elif [[ -f "$destination" ]]; then
    log "Replacing unverified existing file: $filename"
  fi
  log "DOWNLOAD: $os $version ($build) — $name [$devices]"
  try=1
  while [[ "$try" -le "$MAX_RETRY" ]]; do
    log "TRY $try/$MAX_RETRY: $filename"
    if curl --fail --show-error --location --retry 2 --retry-delay 3 --continue-at - --output "$partial" "$url"; then
      if verify_file_size "$partial" "$expected" && mv "$partial" "$destination"; then
        log "DOWNLOAD OK: $filename"
        record_result successful "$os" "$version" "$build" "$devices" "$expected" "$url" "$filename"
        return 0
      fi
      actual=$(get_file_size "$partial" 2>/dev/null || printf unknown)
      log "SIZE MISMATCH: $filename expected=$expected actual=$actual"
      rm -f "$partial"
    else
      log "CURL ERROR: $filename"
    fi
    try=$((try + 1))
    sleep 3
  done
  log "DOWNLOAD FAILED: $filename"
  record_result failed "$os" "$version" "$build" "$devices" "$expected" "$url" "$filename"
  return 0
}

while IFS=$'\t' read -r os version build name devices filename url; do
  # macOS ships Bash 3.2, which does not support `wait -n`.
  while [[ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$MAX_CONCURRENT" ]]; do sleep 1; done
  download_one "$os" "$version" "$build" "$name" "$devices" "$filename" "$url" &
done < <(sort -u -t $'\t' -k6,6 "$QUEUE")
wait

for result in "$RESULTS_DIR"/successful.*.tsv; do [[ -f "$result" ]] && cat "$result" >> "$SUCCESSFUL"; done
for result in "$RESULTS_DIR"/failed.*.tsv; do [[ -f "$result" ]] && cat "$result" >> "$FAILED"; done

if [[ -s "$SUCCESSFUL" ]]; then
  manifest_tmp="$WORK_DIR/manifest.new.$$.tsv"
  awk -F $'\t' 'NF >= 7 { key=$1 FS $2 FS $3 FS $7; if (!(key in replaced)) print }' "$MANIFEST" > "$manifest_tmp"
  cat "$SUCCESSFUL" >> "$manifest_tmp"
  awk -F $'\t' 'NF >= 7 { key=$1 FS $2 FS $3 FS $7; rows[key]=$0 } END { for (key in rows) print rows[key] }' "$manifest_tmp" > "$MANIFEST"
  rm -f "$manifest_tmp"
fi

if [[ "$REMOVE_OLDER" == 1 && "$DRY_RUN" != 1 && -s "$SUCCESSFUL" ]]; then
  log "REMOVE OLDER START"
  while IFS=$'\t' read -r os version build devices size url filename; do
    folder=$(destination_for_os "$os" 2>/dev/null || true)
    [[ -n "$folder" ]] || continue
    family=$(firmware_family "$filename")
    major=${version%%.*}
    [[ -n "$family" ]] || continue
    for old_path in "$DESTINATION_BASE/$folder"/*.ipsw; do
      [[ -f "$old_path" ]] || continue
      old_name=${old_path##*/}
      [[ "$old_name" == "$filename" ]] && continue
      [[ "$(firmware_family "$old_name")" == "$family" ]] || continue
      old_version=$(firmware_version "$old_name")
      [[ -n "$old_version" && "${old_version%%.*}" == "$major" ]] || continue
      if version_less_than "$old_version" "$version"; then
        log "DELETE OLD: $old_name"
        rm -f "$old_path"
      fi
    done
  done < "$SUCCESSFUL"
  log "REMOVE OLDER END"
fi

verify_error=0
if [[ "$VERIFY_ALL" == 1 && "$DRY_RUN" != 1 ]]; then
  log "VERIFY ALL START"
  while IFS=$'\t' read -r os version build devices size url filename; do
    folder=$(destination_for_os "$os" 2>/dev/null || true)
    [[ -n "$folder" ]] || continue
    if [[ ! -f "$DESTINATION_BASE/$folder/$filename" ]] || ! verify_file_size "$DESTINATION_BASE/$folder/$filename" "$size"; then
      log "VERIFY ERROR: $filename"
      verify_error=1
    fi
  done < "$MANIFEST"
  log "VERIFY ALL END"
fi

success_count=$(grep -c . "$SUCCESSFUL" 2>/dev/null || true)
failed_count=$(grep -c . "$FAILED" 2>/dev/null || true)
log "Completed latest $CHANNEL download check: downloaded=$success_count failed=$failed_count verify_error=$verify_error"
[[ "$failed_count" -eq 0 && "$verify_error" -eq 0 ]]
