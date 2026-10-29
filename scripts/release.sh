#!/bin/bash
# Build a universal, Developer ID–signed, notarized DeskSkate.zip and publish it as the GitHub
# release v$(cat VERSION). The landing page links releases/latest, so it updates by itself.
# Needs: the "Developer ID Application" identity in the keychain, and an App Store Connect API
# key JSON (key_id, issuer_id, key) at $ASC_KEY_JSON (default ~/.config/asc/fbc-key.json).
# Usage: scripts/release.sh [--no-publish]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)}
[[ -n "$IDENTITY" ]] || { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }
KEY_JSON=${ASC_KEY_JSON:-$HOME/.config/asc/fbc-key.json}

UNIVERSAL=1 SIGN_IDENTITY="$IDENTITY" scripts/bundle.sh
APP=build/DeskSkate.app
codesign --verify --strict --deep "$APP"

# notarytool wants the key as a .p8 file.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P8="$TMP/key.p8"
read -r KEY_ID ISSUER < <(python3 - "$KEY_JSON" "$P8" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT, 0o600)
os.write(fd, d["key"].encode()); os.close(fd)
print(d["key_id"], d["issuer_id"])
PY
)

ZIP=site/DeskSkate.zip
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --key "$P8" --key-id "$KEY_ID" --issuer "$ISSUER" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"
echo "archs: $(lipo -archs "$APP/Contents/MacOS/DeskSkate")"

if [[ "${1:-}" != "--no-publish" ]]; then
  gh release create "v$VERSION" "$ZIP" --title "DeskSkate $VERSION" --notes-file - <<NOTES
Signed with Developer ID and notarized by Apple, so it opens normally after download.
Apple silicon and Intel, macOS 14+. Unzip and move DeskSkate.app to Applications.
NOTES
fi
