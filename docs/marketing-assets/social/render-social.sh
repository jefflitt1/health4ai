#!/usr/bin/env bash
# Renders tracker-flow-social.html to web/public/brand/tracker-flow-social.png (1200x630).
set -euo pipefail
cd "$(dirname "$0")"
OUT="$PWD/../../../web/public/brand/tracker-flow-social.png"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars \
  --allow-file-access-from-files --window-size=1200,630 --force-device-scale-factor=1 \
  --screenshot="$OUT" "file://$PWD/tracker-flow-social.html" 2>/dev/null
sips -g pixelWidth -g pixelHeight "$OUT" | tail -2
