#!/bin/bash
# Paste this into an Automator "Run Shell Script" action.
#   Shell: /bin/bash          Pass input: as arguments
#
# It keeps a copy of sync-latest.sh from the catalog repository and runs it for
# the two folders below. Edit the three settings if the paths or the machine's
# devices differ.
IPHONE_DEST="/Volumes/IPSW/iPhone Software Updates"
IPAD_DEST="/Volumes/IPSW/iPad Software Updates"
DEVICES=""            # empty means every device; e.g. "iPhone18,5,iPad16,1"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
SOURCE="https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/scripts/sync-latest.sh"
SUPPORT="$HOME/Library/Application Support/ipsw-link-catalog"
LOG="$HOME/Library/Logs/ipsw-link-catalog/sync.log"
mkdir -p "$SUPPORT" "$(dirname "$LOG")"

note() { osascript -e "display notification \"$2\" with title \"IPSW sync\" subtitle \"$1\"" >/dev/null 2>&1; }
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# A drive that is not mounted is the normal case for a laptop at night, not a
# failure worth shouting about; the next run will pick it up.
volume="/Volumes/$(printf '%s' "${IPHONE_DEST#/Volumes/}" | cut -d/ -f1)"
if [ ! -d "$volume" ]; then
  log "skipped: $volume is not mounted"
  note "Skipped" "$volume is not mounted"
  exit 0
fi

# Keep the downloader current, but never run a truncated download of it.
if curl -fsSL --max-time 60 "$SOURCE" -o "$SUPPORT/sync-latest.sh.new" \
   && bash -n "$SUPPORT/sync-latest.sh.new" 2>/dev/null; then
  mv -f "$SUPPORT/sync-latest.sh.new" "$SUPPORT/sync-latest.sh"
else
  rm -f "$SUPPORT/sync-latest.sh.new"
  log "could not refresh sync-latest.sh; using the copy already here"
fi
[ -f "$SUPPORT/sync-latest.sh" ] || { log "no sync-latest.sh available"; note "Failed" "downloader missing"; exit 1; }

log "starting"
JOBS=2 PRUNE=delete DEVICES="$DEVICES" \
  bash "$SUPPORT/sync-latest.sh" "ios=$IPHONE_DEST" "ipados=$IPAD_DEST" >> "$LOG" 2>&1
status=$?
if [ "$status" -eq 0 ]; then
  log "finished"
  note "Up to date" "$(tail -n 1 "$LOG")"
else
  log "failed with status $status"
  note "Failed" "See $LOG"
fi
exit "$status"
