#!/bin/bash
# Build DeskSkate.app (menu bar app, no Dock icon) into build/, install it to /Applications.
# Usage: scripts/bundle.sh [--open]
#   UNIVERSAL=1      build for Apple silicon and Intel
#   SIGN_IDENTITY=…  sign with that identity (hardened runtime, timestamp) instead of ad hoc
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
if [[ "${UNIVERSAL:-}" == 1 ]]; then
  swift build -c release --product DeskSkate --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/DeskSkate
else
  swift build -c release --product DeskSkate
  BIN=.build/release/DeskSkate
fi
APP=build/DeskSkate.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DeskSkate"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.harborapps.deskskate</string>
  <key>CFBundleName</key><string>DeskSkate</string>
  <key>CFBundleExecutable</key><string>DeskSkate</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>DeskSkate asks Finder where your desktop icons are so the skater can ride on them.</string>
</dict></plist>
PLIST
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --entitlements assets/DeskSkate.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP" >/dev/null
fi
echo "built $APP"
if [[ "${1:-}" == "--open" ]]; then
  pkill -x DeskSkate 2>/dev/null || true
  for _ in $(seq 50); do pgrep -x DeskSkate >/dev/null || break; sleep 0.1; done
fi
rm -rf /Applications/DeskSkate.app
cp -R "$APP" /Applications/DeskSkate.app
echo "installed /Applications/DeskSkate.app"
if [[ "${1:-}" == "--open" ]]; then
  open /Applications/DeskSkate.app
fi
