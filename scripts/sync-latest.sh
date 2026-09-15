#!/bin/bash
# Keep a folder in step with the latest signed IPSWs for an operating system.
#
#   sync-latest.sh ios=/Volumes/IPSW/iOS ipados=/Volumes/IPSW/iPadOS
#
# Downloads what is missing, resumes what was interrupted, verifies every file
# against Apple's SHA-1, and removes the builds those replace. Running it again
# is cheap: a file that is already correct is left alone.
#
#   JOBS=2            transfers at once
#   PRUNE=delete      delete|keep older builds of a device once replaced
#   DEVICES=          comma-separated identifiers; empty means every device
#   CATALOG=...       catalog base URL
#
# --install-daily HH:MM installs it as a launchd job that runs every day.
set -u

CATALOG="${CATALOG:-https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api}"
JOBS="${JOBS:-2}"
PRUNE="${PRUNE:-delete}"
DEVICES="${DEVICES:-}"
LABEL="com.github.4ge6n.ipsw-link-catalog.sync"

die() { printf 'sync-latest: %s\n' "$*" >&2; exit 1; }
command -v python3 >/dev/null || die "python3 is required (install Xcode command line tools)"
command -v curl >/dev/null || die "curl is required"

install_daily() {
  at="$1"; shift
  case "$at" in [0-9][0-9]:[0-9][0-9]) ;; *) die "give the time as HH:MM" ;; esac
  hour="${at%%:*}"; minute="${at##*:}"
  [ "$#" -gt 0 ] || die "name at least one os=path pair to sync"
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  plist="$HOME/Library/LaunchAgents/$LABEL.plist"
  logs="$HOME/Library/Logs/ipsw-link-catalog"
  mkdir -p "$(dirname "$plist")" "$logs" || die "cannot create $plist"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0"><dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "$LABEL"
    printf '  <key>ProgramArguments</key><array>\n'
    printf '    <string>/bin/bash</string><string>%s</string>\n' "$self"
    for pair in "$@"; do printf '    <string>%s</string>\n' "$pair"; done
    printf '  </array>\n'
    printf '  <key>EnvironmentVariables</key><dict>\n'
    printf '    <key>JOBS</key><string>%s</string>\n' "$JOBS"
    printf '    <key>PRUNE</key><string>%s</string>\n' "$PRUNE"
    printf '    <key>DEVICES</key><string>%s</string>\n' "$DEVICES"
    printf '  </dict>\n'
    printf '  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>%d</integer><key>Minute</key><integer>%d</integer></dict>\n' "$((10#$hour))" "$((10#$minute))"
    # A Mac that was asleep at the appointed time runs it on waking instead.
    printf '  <key>RunAtLoad</key><false/>\n'
    printf '  <key>StandardOutPath</key><string>%s/sync.log</string>\n' "$logs"
    printf '  <key>StandardErrorPath</key><string>%s/sync.log</string>\n' "$logs"
    printf '</dict></plist>\n'
  } > "$plist" || die "cannot write $plist"
  launchctl unload "$plist" 2>/dev/null
  launchctl load "$plist" || die "launchctl could not load $plist"
  printf 'Installed: runs every day at %s\n' "$at"
  printf '  job     %s\n' "$plist"
  printf '  log     %s/sync.log\n' "$logs"
  printf '  run now launchctl start %s\n' "$LABEL"
  printf '  remove  launchctl unload %s && rm %s\n' "$plist" "$plist"
  exit 0
}

if [ "${1:-}" = "--install-daily" ]; then
  [ "$#" -ge 2 ] || die "usage: --install-daily HH:MM os=path [os=path ...]"
  when="$2"; shift 2
  install_daily "$when" "$@"
fi
[ "$#" -gt 0 ] || die "usage: sync-latest.sh os=path [os=path ...]   (e.g. ios=/Volumes/IPSW/iOS)"

work="$(mktemp -d)"
trap 'touch "$work/monitor.stop" 2>/dev/null; rm -rf "$work"' EXIT
printf 0 > "$work/count"
printf 0 > "$work/block"

model_key() { printf '%s' "$1" | sed -E 's/_[0-9][^_]*_[A-Za-z0-9]+_Restore\.ipsw$//'; }
human() {
  awk -v bytes="$1" 'BEGIN{ if (bytes <= 0) { printf "unknown size"; exit }
    split("B KiB MiB GiB TiB", unit, " "); i = 1
    while (bytes >= 1024 && i < 5) { bytes /= 1024; i++ }
    printf "%.1f %s", bytes, unit[i] }'
}
draw_lock() { while ! mkdir "$work/draw" 2>/dev/null; do sleep 0.05; done; }
draw_unlock() { rmdir "$work/draw" 2>/dev/null; }
clear_block() {
  drawn="$(cat "$work/block" 2>/dev/null || echo 0)"
  [ "$drawn" -gt 0 ] && [ -t 2 ] && printf "\033[%dA\033[J" "$drawn" >&2
  printf 0 > "$work/block"
}
say() { draw_lock; clear_block; printf '%s\n' "$*"; draw_unlock; }

monitor() {
  while [ ! -e "$work/monitor.stop" ]; do
    draw_lock; clear_block; lines=0
    for progress_file in "$work"/progress.*; do
      [ -f "$progress_file" ] || continue
      IFS="$(printf '\t')" read -r active expected began from < "$progress_file" || continue
      bytes="$(wc -c < "$active" 2>/dev/null | tr -d ' ')"
      awk -v name="$(model_key "$(basename "$active")")" -v bytes="${bytes:-0}" -v total="${expected:-0}" \
          -v began="${began:-0}" -v from="${from:-0}" -v now="$(date +%s)" '
        function human(b,  unit, i) {
          split("B KiB MiB GiB TiB", unit, " "); i = 1
          while (b >= 1024 && i < 5) { b /= 1024; i++ }
          return sprintf("%.1f %s", b, unit[i])
        }
        BEGIN {
          pct = total > 0 ? int(bytes * 100 / total) : 0; if (pct > 100) pct = 100
          filled = int(pct * 20 / 100); bar = ""
          for (i = 0; i < 20; i++) bar = bar (i < filled ? "#" : ".")
          seconds = now - began
          rate = seconds > 0 ? (bytes - from) / seconds : 0
          speed = rate > 0 ? human(rate) "/s" : "--"
          eta = "--"
          if (rate > 0 && total > bytes) {
            left = int((total - bytes) / rate)
            eta = left >= 3600 ? sprintf("%dh%02dm", left / 3600, (left % 3600) / 60) \
                : left >= 60 ? sprintf("%dm%02ds", left / 60, left % 60) : sprintf("%ds", left)
          }
          printf "  %-26.26s [%s] %3d%%  %9s / %-9s %10s  ETA %s\n", name, bar, pct, human(bytes), human(total), speed, eta
        }' >&2
      lines=$((lines + 1))
    done
    printf '%s' "$lines" > "$work/block"
    draw_unlock
    sleep 1
  done
  draw_lock; clear_block; draw_unlock
}

checksum() { shasum -a 1 "$1" | awk '{print $1}'; }
stamp() { stat -f '%z %m' "$1" 2>/dev/null || stat -c '%s %Y' "$1" 2>/dev/null; }

# Hashing every file on every run would read hundreds of gigabytes a day, so a
# file whose size and modification time still match what was verified before is
# taken on trust; anything else is hashed.
trusted() {
  path="$1"; want="$2"; state="$(dirname "$path")/.ipsw-sync-state"
  [ -f "$path" ] && [ -n "$want" ] || return 1
  if [ -f "$state" ]; then
    known="$(awk -F"\t" -v name="$(basename "$path")" '$1 == name { print $2 "\t" $3 }' "$state")"
    [ "$known" = "$(stamp "$path" | tr ' ' "$(printf '\t')")	$want" ] && return 0
  fi
  [ "$(checksum "$path")" = "$want" ] || return 1
  remember "$path" "$want"
}

remember() {
  path="$1"; want="$2"; state="$(dirname "$path")/.ipsw-sync-state"
  name="$(basename "$path")"
  while ! mkdir "$work/state" 2>/dev/null; do sleep 0.05; done
  [ -f "$state" ] && grep -v "^$name	" "$state" > "$state.new" 2>/dev/null || : > "$state.new"
  printf '%s\t%s\t%s\n' "$name" "$(stamp "$path" | tr ' ' "$(printf '\t')")" "$want" >> "$state.new"
  mv -f "$state.new" "$state"
  rmdir "$work/state"
}

fetch() {
  index="$1"; url="$2"; sha1="$3"; dest="$4"; name="${url##*/}"; path="$dest/$name"
  if trusted "$path" "$sha1"; then say "  have   $name"; record >/dev/null; return 0; fi
  size="$(curl -sIL "$url" | awk 'tolower($1) == "content-length:" { n = $2 } END { printf "%d", n + 0 }')"
  # A file that is already the full length but hashes wrong is not a partial
  # download, so resuming would only append to damaged bytes.
  if [ -f "$path" ] && [ "$size" -gt 0 ] && [ "$(wc -c < "$path" | tr -d ' ')" -ge "$size" ]; then
    say "  redo   $name (the copy on disk does not match Apple's checksum)"
    rm -f "$path"
  fi
  say "  get    $name ($(human "$size"))"
  attempt=1
  while : ; do
    started=$SECONDS
    from="$( [ -f "$path" ] && wc -c < "$path" | tr -d ' ' || echo 0 )"
    printf '%s\t%s\t%s\t%s\n' "$path" "$size" "$(date +%s)" "$from" > "$work/progress.$index"
    if ! curl -fL -C - --retry 3 --retry-delay 5 -sS -o "$path" "$url"; then
      rm -f "$work/progress.$index"; echo "$name (download failed)" >> "$work/failed"; return 1
    fi
    rm -f "$work/progress.$index"
    if [ -z "$sha1" ] || [ "$(checksum "$path")" = "$sha1" ]; then break; fi
    if [ "$attempt" -eq 1 ]; then
      # A resumed transfer can inherit damage from what was already there.
      say "  redo   $name (checksum did not match; fetching it whole)"
      rm -f "$path"; attempt=2; continue
    fi
    mv -f "$path" "$path.sha1-mismatch"
    say "  !!     SHA-1 mismatch for $name, kept as $name.sha1-mismatch"
    echo "$name (SHA-1 mismatch)" >> "$work/failed"; return 1
  done
  [ -n "$sha1" ] && remember "$path" "$sha1"
  say "  ok     $name in $((SECONDS - started))s$( [ -n "$sha1" ] && printf ', SHA-1 verified')"
  record >/dev/null
}

record() {
  while ! mkdir "$work/lock" 2>/dev/null; do sleep 0.05; done
  count=$(($(cat "$work/count") + 1)); printf '%s' "$count" > "$work/count"
  rmdir "$work/lock"; printf '%s' "$count"
}

monitor &
monitor_pid=$!
index=0
for pair in "$@"; do
  os_key="${pair%%=*}"; dest="${pair#*=}"
  [ "$os_key" != "$pair" ] || die "expected os=path, got '$pair'"
  case "$dest" in "~") dest="$HOME";; "~/"*) dest="$HOME/${dest#\~/}";; esac
  mkdir -p "$dest" || die "cannot create $dest"
  say "$os_key -> $dest"
  listing="$work/$os_key.tsv"
  curl -fsSL "$CATALOG/$os_key/release/latest.json" > "$work/$os_key.json" \
    || die "cannot read the catalog for $os_key"
  DEVICES="$DEVICES" python3 - "$work/$os_key.json" > "$listing" <<'PY'
import json, os, sys
wanted = {d.strip() for d in os.environ.get("DEVICES", "").split(",") if d.strip()}
document = json.load(open(sys.argv[1]))
for release in document.get("releases", []):
    for firmware in release.get("firmwares", []):
        if not firmware.get("signed"): continue
        if wanted and not wanted.intersection(firmware.get("devices") or []): continue
        print("\t".join([firmware["url"], firmware.get("sha1") or "", firmware["filename"]]))
PY
  [ -s "$listing" ] || { say "  nothing to sync"; continue; }
  wanted_names=""
  while IFS="$(printf '\t')" read -r url sha1 filename; do
    wanted_names="$wanted_names $filename"
  done < "$listing"
  while IFS="$(printf '\t')" read -r url sha1 filename; do
    index=$((index + 1))
    if [ "$JOBS" -le 1 ]; then
      fetch "$index" "$url" "$sha1" "$dest"
    else
      fetch "$index" "$url" "$sha1" "$dest" &
      while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$((JOBS + 1))" ]; do sleep 0.5; done
    fi
  done < "$listing"
  for pid in $(jobs -pr); do [ "$pid" = "$monitor_pid" ] || wait "$pid"; done
  if [ "$PRUNE" = "delete" ]; then
    for other in "$dest"/*.ipsw; do
      [ -e "$other" ] || continue
      base="$(basename "$other")"
      case " $wanted_names " in *" $base "*) continue;; esac
      key="$(model_key "$base")"
      for filename in $wanted_names; do
        if [ "$(model_key "$filename")" = "$key" ]; then
          rm -f "$other" && say "  pruned $base"
          break
        fi
      done
    done
  fi
done

touch "$work/monitor.stop"
wait "$monitor_pid" 2>/dev/null
draw_lock; clear_block; draw_unlock
if [ -f "$work/failed" ]; then
  printf 'Sync incomplete:\n' >&2
  sed 's/^/  /' "$work/failed" >&2
  exit 1
fi
printf 'Sync complete: %s file(s) present.\n' "$(cat "$work/count")"
