#!/usr/bin/env bash
# Runs the sleep_for_night parity test against the LOCAL jgle-test-db only (never prod).
# Splices migration 014 into the test with public.* rewritten to the scratch schema and the
# role GRANT/REVOKE lines stripped (those roles are not needed to test the logic).
set -euo pipefail
cd "$(dirname "$0")/../.."
mig=supabase/migrations/014_healthkit_sleep_for_night.sql
out=$(mktemp -t sleep_parity.XXXXXX).sql
fnf=$(mktemp -t sleep_parity_fn.XXXXXX)
sed -e 's/public\.healthkit_metrics/h4ai_parity.healthkit_metrics/g' \
    -e 's/public\.healthkit_sleep_for_night/h4ai_parity.healthkit_sleep_for_night/g' \
    -e 's/SET search_path = public, pg_temp/SET search_path = h4ai_parity, pg_temp/' \
    -e '/^REVOKE /d' -e '/^GRANT /d' "$mig" > "$fnf"
sed -e "/^-- @@FUNCTION@@/{r $fnf" -e 'd' -e '}' supabase/tests/sleep_for_night_parity.test.sql > "$out"
JGLE_DB_PURPOSE=test ~/jgle-systems/bin/jgle-test-db query -f "$out"
