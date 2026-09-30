#!/bin/sh
# Xcode Cloud runs this before every xcodebuild action. It turns the Google Sheets destination
# ON for a Release build when, and only when, the workflow sets H4A_ENABLE_SHEETS=1.
# Default (variable unset): Sheets is compiled out. See docs/sheets-build-gate.md.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PBXPROJ="${H4A_PBXPROJ:-$SCRIPT_DIR/../Health4AI.xcodeproj/project.pbxproj}"

case "${H4A_ENABLE_SHEETS:-}" in
  "")
    # Fail closed: an unset variable must mean Sheets is OFF, so a committed non-empty
    # H4A_RELEASE_CONDITIONS (someone checked the flag in) stops the build here.
    if ! grep -q 'H4A_RELEASE_CONDITIONS = "";' "$PBXPROJ"; then
      echo "H4A_ENABLE_SHEETS is unset but H4A_RELEASE_CONDITIONS in $PBXPROJ is not empty (or missing): refusing to build an App Store configuration that may contain Sheets." >&2
      exit 67
    fi
    echo "H4A_ENABLE_SHEETS not set: building WITHOUT Google Sheets (App Store configuration)."
    exit 0
    ;;
  1) ;;
  *)
    echo "H4A_ENABLE_SHEETS must be 1 or unset, got '${H4A_ENABLE_SHEETS}'." >&2
    exit 64
    ;;
esac

if grep -q 'H4A_RELEASE_CONDITIONS = "H4A_SHEETS";' "$PBXPROJ"; then
  echo "H4A_SHEETS already enabled in $PBXPROJ."
  exit 0
fi
if ! grep -q 'H4A_RELEASE_CONDITIONS = "";' "$PBXPROJ"; then
  echo "Could not find the empty H4A_RELEASE_CONDITIONS setting in $PBXPROJ" >&2
  exit 65
fi

echo "H4A_ENABLE_SHEETS=1: building WITH Google Sheets (TestFlight-only configuration)."
sed -i '' 's/H4A_RELEASE_CONDITIONS = "";/H4A_RELEASE_CONDITIONS = "H4A_SHEETS";/g' "$PBXPROJ"

if ! grep -q 'H4A_RELEASE_CONDITIONS = "H4A_SHEETS";' "$PBXPROJ"; then
  echo "Failed to enable H4A_SHEETS in $PBXPROJ" >&2
  exit 66
fi
