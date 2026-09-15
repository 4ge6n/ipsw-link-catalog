#!/bin/bash
# Build IPSWSync.app. SwiftPM produces a bare executable, so the bundle around
# it — the one macOS needs for a menu bar item, notifications and login items —
# is assembled here.
set -euo pipefail
cd "$(dirname "$0")"

CONFIGURATION="${CONFIGURATION:-release}"
APP="${1:-$PWD/IPSWSync.app}"

swift build -c "$CONFIGURATION" --disable-sandbox
binary="$(swift build -c "$CONFIGURATION" --show-bin-path)/IPSWSync"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$binary" "$APP/Contents/MacOS/IPSWSync"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>IPSW Sync</string>
  <key>CFBundleDisplayName</key><string>IPSW Sync</string>
  <key>CFBundleExecutable</key><string>IPSWSync</string>
  <key>CFBundleIdentifier</key><string>com.github.4ge6n.ipsw-link-catalog.IPSWSync</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>IPSW link catalog</string>
</dict>
</plist>
PLIST

# An ad-hoc signature is enough to run it locally, and login items and
# security-scoped bookmarks need the bundle to be signed at all.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
  printf 'warning: could not sign the bundle; it will still run\n' >&2
}
printf 'Built %s\n' "$APP"
