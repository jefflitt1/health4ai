#!/bin/sh
# Xcode Cloud runs this before every xcodebuild action. Google Sheets ships in every build from
# 1.0.1 on (Google OAuth app published and brand-verified 2026-09-30), so Release must compile
# H4A_SHEETS. Fail closed if the committed setting no longer says so. See docs/sheets-build-gate.md.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PBXPROJ="${H4A_PBXPROJ:-$SCRIPT_DIR/../Health4AI.xcodeproj/project.pbxproj}"

if ! grep -q 'H4A_RELEASE_CONDITIONS = "H4A_SHEETS";' "$PBXPROJ"; then
  echo "H4A_RELEASE_CONDITIONS in $PBXPROJ is not \"H4A_SHEETS\": refusing to build a Release without Google Sheets." >&2
  exit 67
fi
echo "Building WITH Google Sheets."
