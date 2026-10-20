#!/usr/bin/env bash
# lint-migration-grants.sh - run scripts/check-migration-grants.py over this repo's migration registries.
#
# WHY: Supabase stops auto-granting Data API access (anon / authenticated / service_role) on NEW `public`
# tables on 2026-10-30. A migration that creates a public table without an explicit GRANT then answers 42501
# to supabase-js and PostgREST (service_role included). The grant must ship in the migration that creates
# the table. Template: scripts/migration-templates/public_table.sql. Rules G001-G005: scripts/check-migration-grants.py.
# Findings in migrations applied before this check are frozen in scripts/migration-grants-baseline.txt; the
# baseline only shrinks. Re-seed after fixing: scripts/lint-migration-grants.sh --write-baseline
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/check-migration-grants.py \
  --baseline scripts/migration-grants-baseline.txt \
  --exclude '*/tests/*' --exclude '*/fixtures/*' --exclude '*/rollback/*' --exclude '*/templates/*' \
  --exclude '*/migration-templates/*' --exclude '*.rollback.sql' --exclude '*.down.sql' --exclude '*.test.sql' \
  --exclude '*/rollback.sql' --exclude '*/fixture.sql' \
  "$@" \
  supabase/migrations \
  supabase/ops \
  supabase/upgrades \
  web/public/schema.sql
