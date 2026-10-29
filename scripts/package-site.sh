#!/bin/bash
# Zip build/DeskSkate.app into site/DeskSkate.zip for the landing page download.
# Usage: scripts/package-site.sh [--build]   (--build runs scripts/bundle.sh first, which also
# installs to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == "--build" ]]; then scripts/bundle.sh; fi
APP=build/DeskSkate.app
[[ -d "$APP" ]] || { echo "no $APP; run with --build" >&2; exit 1; }
mkdir -p site
rm -f site/DeskSkate.zip
ditto -c -k --keepParent "$APP" site/DeskSkate.zip
echo "archs: $(lipo -archs "$APP/Contents/MacOS/DeskSkate")"
codesign -dv "$APP" 2>&1 | grep -E "^(Authority|Signature)" || true
ls -lh site/DeskSkate.zip
