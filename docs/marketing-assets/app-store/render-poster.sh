#!/usr/bin/env bash
# Renders tracker-flow-poster.html to the App Store 6.9" screenshot (1290x2796 = 430x932 @3x).
set -euo pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
  --window-size=430,932 --force-device-scale-factor=3 \
  --screenshot="$PWD/tracker-flow-screenshot-2.png" "file://$PWD/tracker-flow-poster.html" 2>/dev/null
sips -g pixelWidth -g pixelHeight tracker-flow-screenshot-2.png | tail -2
