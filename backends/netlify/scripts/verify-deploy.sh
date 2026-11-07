#!/usr/bin/env bash
# Checks a deployed backend end to end: setup secret, Device key issue/revoke, ingest and merged
# hours. Usage: scripts/verify-deploy.sh https://your-site.netlify.app
#
# Reads the setup secret from $HEALTH4AI_SETUP_SECRET and never prints it:
#   HEALTH4AI_SETUP_SECRET=$(pnpm -s run setup-secret) scripts/verify-deploy.sh <site url>
# Writes fixture step rows for 2000-01-01 00:00-01:00 UTC under the Owner. The per-device ones are
# replaced by the merged hour, so one row remains. Remove it afterwards with:
#   DELETE FROM healthkit_metrics
#    WHERE metric_type = 'HKQuantityTypeIdentifierStepCount'
#      AND source_device IN ('verify-deploy', 'HealthKit (all sources)')
#      AND started_at >= '2000-01-01T00:00:00Z' AND started_at < '2000-01-01T01:00:00Z';
set -euo pipefail

BASE=${1:?usage: $0 <site url>}
SECRET=${HEALTH4AI_SETUP_SECRET:?set HEALTH4AI_SETUP_SECRET to the setup secret, which pnpm -s run setup-secret prints}
fail=0
# The secret goes to curl through a fresh file descriptor per call (`-H @<(secret_header)`),
# never argv, so `ps` cannot show it.
secret_header() { printf 'X-Setup-Secret: %s' "$SECRET"; }

# check <label> <expected status> <expected body substring> <curl args...>
check() {
  local label=$1 want_status=$2 want_body=$3; shift 3
  local out status body
  out=$(curl -s -w $'\n%{http_code}' "$@")
  status=${out##*$'\n'}
  body=${out%$'\n'*}
  if [[ $status == "$want_status" && $body == *"$want_body"* ]]; then
    echo "ok   $label"
  else
    echo "FAIL $label: got $status $body"
    fail=1
  fi
  LAST_BODY=$body
}

field() { python3 -I -c "import sys,json; print(json.loads(sys.argv[1])[sys.argv[2]])" "$LAST_BODY" "$1"; }

check 'setup without secret is refused' 403 'Wrong setup secret' "$BASE/api/setup"
check 'setup shows the Owner ID' 200 'person_id' -H @<(secret_header) "$BASE/api/setup"
check 'issue a Device key' 201 '"key":"h4a_' -X POST -H @<(secret_header) \
  -d '{"label":"verify-deploy"}' "$BASE/api/setup/keys"
if [[ $fail == 1 ]]; then echo "stopping: no Device key to test ingest with"; exit 1; fi
KEY=$(field key)
KEY_ID=$(field id)
# Revoke the key however the script ends, so an abort cannot leave a live write key behind.
cleanup() {
  [[ -n ${KEY_ID:-} ]] && curl -s -o /dev/null -X POST -H @<(secret_header) \
    "$BASE/api/setup/keys/$KEY_ID/revoke"
}
trap cleanup EXIT

check 'ingest without a key is 401' 401 'Missing Authorization header' -X POST -d '{}' "$BASE/api/ingest"
check 'empty batch reports capabilities' 200 '"capabilities":["merged_hours_v1"]' -X POST \
  -H "Authorization: Bearer $KEY" -d '{"samples":[]}' "$BASE/api/ingest"
check 'two per-device step rows are stored' 200 '"inserted":2' -X POST -H "Authorization: Bearer $KEY" \
  -d '{"samples":[
    {"metric_type":"HKQuantityTypeIdentifierStepCount","value":10,"unit":"count","source_device":"verify-deploy","started_at":"2000-01-01T00:05:00Z","ended_at":"2000-01-01T00:10:00Z"},
    {"metric_type":"HKQuantityTypeIdentifierStepCount","value":20,"unit":"count","source_device":"verify-deploy","started_at":"2000-01-01T00:40:00Z","ended_at":"2000-01-01T00:45:00Z"}]}' \
  "$BASE/api/ingest"
check 'a merged hour replaces both' 200 '"replaced":2' -X POST -H "Authorization: Bearer $KEY" \
  -d '{"samples":[{"metric_type":"HKQuantityTypeIdentifierStepCount","value":30,"unit":"count","source_device":"HealthKit (all sources)","started_at":"2000-01-01T00:00:00Z","ended_at":"2000-01-01T01:00:00Z"}]}' \
  "$BASE/api/ingest"

check 'revoke the key' 204 '' -X POST -H @<(secret_header) "$BASE/api/setup/keys/$KEY_ID/revoke"
check 'a revoked key is 401' 401 'Unauthorized' -X POST -H "Authorization: Bearer $KEY" \
  -d '{"samples":[]}' "$BASE/api/ingest"

exit $fail
