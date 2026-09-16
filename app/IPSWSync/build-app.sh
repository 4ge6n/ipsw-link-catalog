#!/bin/bash
# Build IPSWSync.app. SwiftPM produces a bare executable, so the bundle around
# it — the one macOS needs for a menu bar item, notifications and login items —
# is assembled here.
set -euo pipefail
cd "$(dirname "$0")"

CONFIGURATION="${CONFIGURATION:-release}"
APP="${1:-$PWD/IPSWSync.app}"
# The build number is the commit count, so a local build is never mistaken for
# being behind the published one.
# The script has already moved into its own directory, which is inside the repo.
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
VERSION="${VERSION:-1.0}"

# Somewhere other than the source drive, when that one is full or slow.
SCRATCH="${SCRATCH:-}"
scratch_args=()
[ -n "$SCRATCH" ] && scratch_args=(--scratch-path "$SCRATCH")

# An empty array is an unbound variable to the bash the runner has, so it is
# expanded only when it holds something.
swift build -c "$CONFIGURATION" --disable-sandbox ${scratch_args[@]+"${scratch_args[@]}"}
binary="$(swift build -c "$CONFIGURATION" ${scratch_args[@]+"${scratch_args[@]}"} --show-bin-path)/IPSWSync"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$binary" "$APP/Contents/MacOS/IPSWSync"

# The strings live in the main bundle rather than as a SwiftPM resource,
# because Text("…") looks them up in Bundle.main and nowhere else.
cp -R Localizations/*.lproj "$APP/Contents/Resources/"

# The icon is drawn rather than checked in, so it stays editable as code.
icons="$(mktemp -d)/IPSWSync.iconset"
mkdir -p "$icons"
swift icon/DrawIcon.swift "$icons" >/dev/null
for size in 16 32 128 256 512; do
  cp "$icons/icon_$size.png" "$icons/icon_${size}x${size}.png"
  double=$((size * 2))
  [ -f "$icons/icon_$double.png" ] && cp "$icons/icon_$double.png" "$icons/icon_${size}x${size}@2x.png"
done
rm -f "$icons"/icon_16.png "$icons"/icon_32.png "$icons"/icon_64.png \
      "$icons"/icon_128.png "$icons"/icon_256.png "$icons"/icon_512.png "$icons"/icon_1024.png
iconutil -c icns "$icons" -o "$APP/Contents/Resources/IPSWSync.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>IPSW Sync</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ja</string></array>
  <key>CFBundleDisplayName</key><string>IPSW Sync</string>
  <key>CFBundleExecutable</key><string>IPSWSync</string>
  <key>CFBundleIconFile</key><string>IPSWSync</string>
  <key>CFBundleIdentifier</key><string>com.github.4ge6n.ipsw-link-catalog.IPSWSync</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>__VERSION__</string>
  <key>CFBundleVersion</key><string>__BUILD__</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHumanReadableCopyright</key><string>IPSW link catalog</string>
</dict>
</plist>
PLIST
sed -i '' -e "s|__VERSION__|$VERSION|" -e "s|__BUILD__|$BUILD|" "$APP/Contents/Info.plist"

# An ad-hoc signature is enough to run it locally, and login items and
# security-scoped bookmarks need the bundle to be signed at all.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
  printf 'warning: could not sign the bundle; it will still run\n' >&2
}
printf 'Built %s\n' "$APP"
