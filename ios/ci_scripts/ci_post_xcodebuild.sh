#!/bin/sh
# Xcode Cloud runs this after every xcodebuild action. For an ARCHIVE it verifies the built app
# contains the Google Sheets destination, and fails the build (so nothing reaches App Store Connect
# or TestFlight) if the flag did not take effect.
# CI_XCODEBUILD_ACTION and CI_ARCHIVE_PATH are Xcode Cloud variables (Apple: Environment variable
# reference, verified 2026-09-30). CI_ARCHIVE_PATH may be an .xcarchive or a directory holding .app.
set -eu

PROBE="sheets.googleapis.com"   # only SheetsClient references it; compiled out without H4A_SHEETS

if [ "${CI_XCODEBUILD_ACTION:-archive}" != "archive" ]; then
  echo "Sheets gate check skipped: action is '${CI_XCODEBUILD_ACTION}', not archive."
  exit 0
fi

ARCHIVE="${CI_ARCHIVE_PATH:-}"
if [ -z "$ARCHIVE" ] || [ ! -e "$ARCHIVE" ]; then
  echo "Sheets gate check cannot run: CI_ARCHIVE_PATH is unset or missing ('$ARCHIVE'). Failing closed." >&2
  exit 70
fi

APP="$(find "$ARCHIVE" -type d -name 'Health4AI.app' | head -1)"
if [ -z "$APP" ]; then
  echo "Sheets gate check cannot find Health4AI.app under $ARCHIVE. Failing closed." >&2
  exit 71
fi

if ! grep -rqaF "$PROBE" "$APP"; then
  echo "FAIL: $APP has no Google Sheets code. H4A_SHEETS did not take effect in Release." >&2
  exit 73
fi
echo "OK: archive contains Google Sheets code."
