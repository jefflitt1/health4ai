# Historical summary precision fix

Verified 2026-11-15. Prepared, not deployed.

## Problem and smallest change

Five AppleStandTime summaries were flagged despite identical sample counts,
minima and maxima. Exact float8 byte comparisons proved SUM differed by one ULP
(absolute differences 1.8e-15 through 2.8e-14). Aggregation order can produce this
without a change in samples. Both current writer and checker compare sums
exactly, so repeat maintenance can rewrite insignificant differences and the
weekly report still declares repairs needed.

Migration 013 restores the historical checker's absolute 1e-6 sum tolerance in
both writer and checker. NULL/nonfinite differences remain explicit; counts,
minima and maxima remain exact. The compaction branch, timezone, cutoff and
raw-retention behavior are preserved. Applying this changes definitions, not data.

## Applicable rules and plan

- `~/AGENTS.md:70`: root cause evidenced before edit; exact float byte comparison.
- `~/AGENTS.md:53`: isolated `fix/summary-float-tolerance` worktree.
- `~/AGENTS.md:61`: regressions in disposable local `jgle-test-db` databases.
- `~/AGENTS.md:47`: independent review before live function replacement;
  regression must fail against exact live definitions first.
- `~/AGENTS.md:40`: PostgreSQL behavior tests, grants lint and file read-back.
- `~/claude-agents/docs/operations/compound-practices.md` section 3: simplify
  changed code only, then repeat affected verification before review.

Root and JGLP/JGLV BU contracts inspected; no project AGENTS.md/CLAUDE.md present.
No matching additional path-specific rule under `~/.claude/rules/*.md`.

## Verification

`python3 scripts/tests/test_summary_sum_tolerance.py --baseline <live-functions.sql>`
failed at `roundoff is not a mismatch: expected 0, got 1` after one initial write.
The exact pre-fix baseline is private temporary evidence, not versioned data.

The same command without `--baseline` passed 46 PostgreSQL assertions: roundoff
ignored by checker and writer, real sum/count/min/max/null/nonfinite defects
detected and repaired, missing summaries recreated, repeat execution idempotent,
raw samples retained, and execution grants checked. Disposable test databases
were dropped in `finally` after both red and green runs.

Independent review caught equal nonfinite sums being marked distinct by the
arithmetic predicate. An exact-equality outer check now prevents that; additional
tests cover equal and unequal positive infinity, negative infinity and NaN.

`python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v` ran 23 tests:
19 passed, 4 existing tests skipped because they need a separate Supabase image.
`scripts/lint-migration-grants.sh`: 23 files, 0 new findings, 0 warnings.
The workflow invokes the actual PostgreSQL regression as its own job.

Simplification: removed redundant inner distinct checks after adding the outer
equality guard; retained NULL/nonfinite checks. Repeated all PostgreSQL assertions.

Target: real summary errors remain detectable and repairable; sub-micro-unit
roundoff neither alerts nor rewrites. Measured: nonzero fixture rows, deliberate
corruptions, actual writer/checker results, and failed pre-fix run.

## Deployment and remaining work

Independent review and production application/readback remain pending. Recheck
current function definitions before applying to avoid overwriting later changes.
After approved application, query all activity-type mismatches using the same
local-day cutoff. Verify five insignificant mismatches become zero and confirm
the next scheduled writer does not rewrite those five days. Zero is justified
by the known baseline discrepancies and corruption tests.
