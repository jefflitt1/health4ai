# Agent workflow and handoff

Approved 2026-11-23. This public-safe guide makes the maintainer workflow usable
from remote sessions. It supplements, rather than replaces, the maintainer's
canonical agent contract and skills. Never copy private health data or credentials
into a PR, CI artifact, or completion receipt.

## Component checks

| Changed component | Required verification |
| --- | --- |
| `backends/netlify/` | Node and pnpm versions from `backends/netlify/mise.toml`; `pnpm install --frozen-lockfile`, `pnpm run typecheck`, `pnpm test` in that directory |
| `mcp-server/` | Full `pytest tests` with the project's dependencies; real local database proof for SQL changes |
| `ios/` | Relevant pure tests, simulator XCTest suite and build; physical-device acceptance for affected HealthKit, background, consent, and destination behavior |
| `web/` | Package build/check commands, actual preview behavior, and independent UX review |
| migrations / ingest | Local database migration, auth/tenant-isolation and write/readback tests; regressions for changed wiring |
| CI / release controls | Positive and negative controls proving broken or missing evidence fails; independent review before activation |

Netlify `pnpm test` includes CPAP parser, UI, upload/API, auth, and the Python
deploy-verifier tests. Database tests create isolated local PGlite instances.
The real SD-card test is deliberately skipped in CI: it requires private hardware
data and must never be represented as covered by synthetic fixtures. Report that
skip separately. No production credentials or real card are needed for CI.

## Merge path

1. Push a focused branch and open a PR with verification evidence.
2. On the connected maintainer Mac, run the existing `/review` skill against that
   PR, including applicable security/UX checks. Resolve required-evidence gaps.
3. The canonical independent writer is invoked with only repository and PR:

   ```sh
   python3 ~/jgle-systems/bin/review-pass-writer.py jefflitt1/health4ai PR_NUMBER
   ```

   The author cannot supply the verdict. It reviews the final head, validates
   coverage, rechecks the PR, and produces the local marker. For this repository
   its GitHub status is `JGLE independent code review`. It is not permission to
   skip any other required check or release acceptance.
4. Confirm all required CI checks passed for the current head, with no unexplained
   skipped component. Follow the canonical CLI merge form from the review skill,
   including `--match-head-commit`. A new push requires a new review.
5. Read back the merge; separately verify any intended deployment. Complete
   authorized contributor replies and read them back.

If the Mac is unavailable, leave the PR open with this receipt. Do not recreate
the reviewer, forge a status, or merge through another surface. GitHub protection
blocks missing checks across surfaces; it does not authenticate a separate human
reviewer when all tools share one account. A writer with that account could forge
a status or alter protection. Stronger isolation requires a separately controlled
review identity. No claim of that isolation is made here.

## Completion receipt

Keep the current receipt in the PR description using the PR template. This is the
shared retrieval location for Dot and CLI sessions, including incomplete work.
Update it after merge/deployment or communication so the handoff is not stale.
For work without a PR, use the existing issue when authorized, or return the
receipt to the user for the next session. Posting requires task authorization.

```text
Source: PR URL; base SHA; final reviewed head SHA; merge SHA or NOT MERGED
Scope: requested outcome and affected components
Verification: command, environment, observed counts/result, evidence URL
Independent review: reviewer/receipt; reviewed SHA; security/UX result or N/A reason
Release: merged / deployed / submitted / public / device-tested, each with evidence
Communication: issue URL -> posted comment URL, or draft/pending with reason
Open: each incomplete acceptance/request, next action, and exact resume command
```

Use PASS, FAIL, BLOCKED, NOT RUN, and NOT APPLICABLE with reasons. A self-written
receipt records observations; it cannot substitute for independent review.
Before resuming, fetch the PR and compare its current head to the receipt. Do not
inherit an earlier commit's tests or approval after code changes.
