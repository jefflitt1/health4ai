#!/bin/sh
# Xcode Cloud runs this after every xcodebuild action. For an ARCHIVE it verifies the built app
# matches the intended Sheets setting, and fails the build (so nothing reaches App Store Connect
# or TestFlight) if not:
#   H4A_ENABLE_SHEETS unset -> the archive must NOT contain the Google Sheets endpoint.
#   H4A_ENABLE_SHEETS=1     -> the archive MUST contain it.
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

if grep -rqaF "$PROBE" "$APP"; then FOUND=1; else FOUND=0; fi

case "${H4A_ENABLE_SHEETS:-}" in
  "")
    if [ "$FOUND" = 1 ]; then
      echo "FAIL: H4A_ENABLE_SHEETS is unset but $APP contains '$PROBE'. This archive would expose Google Sheets to App Review." >&2
      exit 72
    fi
    echo "OK: no Google Sheets code in the archive (App Store configuration)."
    ;;
  1)
    if [ "$FOUND" = 0 ]; then
      echo "FAIL: H4A_ENABLE_SHEETS=1 but $APP has no Sheets code. The flag did not take effect." >&2
      exit 73
    fi
    echo "OK: archive contains Google Sheets code (TestFlight-only configuration)."
    ;;
  *)
    echo "H4A_ENABLE_SHEETS must be 1 or unset, got '${H4A_ENABLE_SHEETS}'." >&2
    exit 64
    ;;
esac
