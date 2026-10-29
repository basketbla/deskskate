#!/bin/bash
# Render the landing-page demo offscreen (no screen recording) and encode it for site/.
# Usage: scripts/render-demo.sh [framesdir]   (frames default to a temp dir, deleted after)
# Needs ffmpeg (brew install ffmpeg).
set -euo pipefail
cd "$(dirname "$0")/.."
FRAMES="${1:-$(mktemp -d -t deskskate-demo)}"
KEEP="${1:+1}"
POSTER_FRAME="${POSTER_FRAME:-930}"
swift build -c release --product DeskSkate
rm -f "$FRAMES"/frame-*.png
# Run a renamed copy so `pkill -x DeskSkate` (bundle.sh --open) can't kill the render.
RENDERER="$(mktemp -d -t deskskate-bin)/deskskate-render"
cp .build/release/DeskSkate "$RENDERER"
"$RENDERER" --render-demo "$FRAMES"
rm -rf "$(dirname "$RENDERER")"
mkdir -p site
ffmpeg -loglevel error -y -framerate 60 -i "$FRAMES/frame-%05d.png" \
  -c:v libx264 -preset slow -crf 23 -pix_fmt yuv420p -movflags +faststart -an site/demo.mp4
ffmpeg -loglevel error -y -i "$FRAMES/$(printf 'frame-%05d.png' "$POSTER_FRAME")" -q:v 3 site/demo-poster.jpg
[[ -z "$KEEP" ]] && rm -rf "$FRAMES"
ls -lh site/demo.mp4 site/demo-poster.jpg
