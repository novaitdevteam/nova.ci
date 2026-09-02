# Authenticated DAST API Scanning and Live-Instance Baseline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scan the engine's authenticated API from its own OpenAPI spec on an ephemeral seeded stack, and baseline the live instance through Cloudflare — without storing any credential.

**Architecture:** The tally-parse, numeric guard and exit-ladder that both ZAP scanners share are extracted into a sourced `dast-common.sh`, because a silent drift there is the exact "guard that measures nothing" failure this repository keeps hitting. A new `dast-api` action boots `novatalks.core`, runs `db:setup:prod`, logs in as the seeded admin, and runs `zap-api-scan.py` in safe mode with the JWT injected via a ZAP replacer rule. A separate `workflow_dispatch` workflow runs `zap-baseline.py` against an allowlisted live URL.

**Tech Stack:** Bash, GitHub Actions composite actions and reusable workflows, OWASP ZAP (`zap-baseline.py`, `zap-api-scan.py`), Docker, `jq`, `curl`, NestJS engine image.

**Spec:** [`docs/superpowers/specs/2026-09-01-dast-api-scan.md`](../specs/2026-09-01-dast-api-scan.md)

## Global Constraints

- `warn-only` governs **findings**. A scanner that could not run reds the job; a scanner that found something must not. Nothing here may make a build red for a finding.
- A stack that fails to boot, migrate, seed or log in is a **loud skip**: green build, explicit `⚠️ not run — <reason>`, same as the existing DAST.
- Scanner images stay pinned by tag **and** digest. Reuse the existing `ZAP_IMAGE` pin; do not introduce `latest`.
- **Safe mode (`-S`) is mandatory** for `zap-api-scan.py` in this branch. Active scanning is out of scope.
- No credential is stored. The seeded admin's password is generated at run time with `openssl rand`, passed to the seed step, used once, and never written outside the runner. `guard-secret-echo.sh` still applies: never `echo` it.
- The tally anchor stays ANSI-C quoted (`$'…\t…'`); GNU grep reads a plain `'\t'` as a literal `t`. This is why the shared code is extracted rather than copied.
- Changing any `scan.sh` means changing its harness in the same commit.
- The live-baseline workflow validates its target against an allowlist; a non-allowlisted URL fails loudly, never scans.
- Every commit ends with the trailer `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- Run `./scripts/validate.sh` after every task; it must end `VALIDATION OK`. Baseline before this plan: SAST 31, DAST 112, secret-echo 23, create-runner 22.

---

### Task 1: Extract the shared ZAP result logic into `dast-common.sh`

**Files:**
- Create: `.github/actions/dast/dast-common.sh`
- Modify: `.github/actions/dast/scan.sh`
- Test: `scripts/test-dast-scan.sh` (must stay green, unchanged count)

**Interfaces:**
- Consumes: nothing.
- Produces: a sourceable library defining `zap_emit`, `zap_tally_parse <console-file>` (sets `failures`/`findings`/`infos`/`accepted`/`passes` or calls the provided error function), used by Task 2. It does **not** define `scanner_error`/`not_run`/`summary`/`emit` — those stay in each caller, because their messages differ. The library takes the error-callback name as an argument so it can call the caller's `scanner_error`.

- [ ] **Step 1: Create the shared library with only the drift-dangerous logic**

Create `.github/actions/dast/dast-common.sh`. It carries the tally anchor, `tally_at`, and the numeric guard — the ~25 lines where a copy silently diverging is catastrophic — and nothing else. The report body, `emit`, `summary`, the outcome/message text all differ between baseline and api-scan and stay in each caller.

```bash
#!/usr/bin/env bash
#
# Shared ZAP result parsing for dast/ and dast-api/. Only the logic where a divergent
# copy would silently measure nothing lives here: the tally-line anchor, tally_at, and
# the numeric guard. Report assembly and notifier text differ per scanner and stay in
# each scan.sh. Sourced, never executed.

# zap_tally_parse <console-file> <error-fn>
# Reads the one tally line ZAP prints at the end of any completed scan and sets the
# globals failures/findings/infos/accepted/passes. Calls <error-fn> (the caller's
# scanner_error) on a missing or non-numeric tally — fail closed, never guess a zero.
#
# The anchor is ANSI-C quoted so the tab is a real byte. GNU grep reads a plain '\t' in
# a pattern as a literal 't' (warning: stray \ before t), so the plainly-quoted form
# matches nothing on every Linux runner and reds every completed scan; only a macOS
# harness run passes it. Anchored on the tally's shape, not the bare FAIL-NEW: prefix,
# because print_rule emits a per-rule FAIL-NEW: <alert> line before the tally.
zap_tally_parse() {
    local console="$1" err_fn="$2" tally
    tally="$(grep -m1 -E $'^FAIL-NEW: [0-9]+\tFAIL-INPROG: ' "$console" || true)"
    [ -n "$tally" ] || { "$err_fn" "ZAP printed no result tally — the scan did not complete"; return; }

    local at() { printf '%s' "$tally" | tr '\t' '\n' | sed -n "s/^$1: //p" | head -1; }
    failures="$(at FAIL-NEW)"; findings="$(at WARN-NEW)"; infos="$(at INFO)"
    accepted="$(at IGNORE)"; passes="$(at PASS)"

    local n
    for n in "$failures" "$findings" "$infos" "$accepted" "$passes"; do
        [[ "$n" =~ ^[0-9]+$ ]] || { "$err_fn" "ZAP tally line is malformed: ${tally}"; return; }
    done
}
```

Note the nested `local at()` is not valid bash — a function cannot be declared `local`. Write it as a plain nested function `_zap_tally_at`, defined once at library top level:

```bash
_zap_tally_at() { printf '%s' "$1" | tr '\t' '\n' | sed -n "s/^$2: //p" | head -1; }
```

and call `failures="$(_zap_tally_at "$tally" FAIL-NEW)"` etc. Fix this in the library before proceeding — do not ship the `local at()` form.

- [ ] **Step 2: Source the library from `dast/scan.sh` and delete the inlined copy**

In `.github/actions/dast/scan.sh`, near the top after the `set` line, source the library by its action-relative path:

```bash
# shellcheck source=.github/actions/dast/dast-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/dast-common.sh"
```

Then replace the inlined block (the `tally="$(grep -m1 …)"` line, its `[ -n "$tally" ]` guard, the `tally_at()` definition, the five `tally_at` assignments, and the numeric `for n in …` loop — currently lines 428–444) with a single call:

```bash
zap_tally_parse "$zap_console" scanner_error
```

`scanner_error` is already defined in `scan.sh` above this point, and `zap_tally_parse` sets the same five globals the rest of the script already reads. Nothing downstream changes.

- [ ] **Step 3: Run the DAST harness to prove behaviour is unchanged**

Run: `./scripts/test-dast-scan.sh`
Expected: `--- 112 passed, 0 failed`. The extraction is behaviour-preserving; any deviation from 112 means the refactor changed something and must be found before continuing.

- [ ] **Step 4: Prove the extraction under GNU grep, not only BSD**

The whole reason this logic is extracted rather than copied is the `\t` divergence. Confirm the sourced form still works under GNU grep:

```bash
PATH="/opt/homebrew/opt/grep/libexec/gnubin:$PATH" ./scripts/test-dast-scan.sh
```

Expected: `112 passed`. If GNU grep is not installed on the executing machine, note that CI's `ci-self-validate.yaml` runs on `ubuntu-latest` (GNU) and will be the real check; do not skip recording that.

- [ ] **Step 5: Run the full validator**

Run: `./scripts/validate.sh`
Expected: `VALIDATION OK`.

- [ ] **Step 6: Commit**

```bash
git add .github/actions/dast/dast-common.sh .github/actions/dast/scan.sh
git commit -m "$(cat <<'EOF'
Extract the ZAP tally parse into a sourced dast-common.sh

The tally anchor, tally_at and the numeric guard are about to have a second
caller (the API scan). Copying them is the one thing this stack has proven
it must not do: the anchor's ANSI-C \t, the shape-not-prefix match and the
fail-closed numeric guard are each a place where a divergent copy reports a
clean scan that never happened. They move into a sourced library so both
callers run the same bytes.

Behaviour-preserving: the DAST harness stays at 112/0, under BSD and GNU
grep both. Report assembly and notifier text differ per scanner and stay in
each scan.sh — only the drift-dangerous logic is shared.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: The `dast-api` action — boot, seed, log in, scan the spec

**Files:**
- Create: `.github/actions/dast-api/action.yml`
- Create: `.github/actions/dast-api/scan.sh`
- Test: `scripts/test-dast-api-scan.sh`

**Interfaces:**
- Consumes: `dast-common.sh` from Task 1 (via a relative source path `../dast/dast-common.sh`).
- Produces: a composite action with inputs `image`, `report-file`, `report-url`, and outputs `outcome` (`clean|findings|not-run|error`), `findings`, `failures`, `message` — the same output contract as `dast`, so Task 3's notifier compose step is a copy of the existing one.

- [ ] **Step 1: Write the harness first — the four outcomes and the safe-mode assertion**

Create `scripts/test-dast-api-scan.sh`, modelled on `scripts/test-dast-scan.sh` (same `docker`/`curl` stub pattern, same `expect`/`assert_*` helpers). It stubs `docker` (postgres, redis, the engine, ZAP) and `curl` (the login and the spec fetch). Scenarios, each a decision branch in `scan.sh`:

```bash
# clean: stack boots, migrates, seeds, login returns a JWT, spec fetched, ZAP finds nothing.
expect "full pipeline, ZAP clean" clean 0
assert_findings "clean api-scan counts zero" 0

# findings: ZAP tally reports WARN-NEW > 0 -> outcome findings, build still green.
expect "api-scan warnings are findings, build green" findings 0
assert_findings "warnings counted from the tally" 5

# must-fix: FAIL-NEW > 0 -> outcome findings, failures set, still green.
assert_failures "FAIL-NEW counted on its own" 2

# not-run: each precondition failure is a loud skip, green, never scanned-clean.
expect "postgres down is a loud skip" not-run 0
expect "migration failure is a loud skip" not-run 0
expect "seed failure is a loud skip" not-run 0
expect "login returns no JWT is a loud skip" not-run 0
expect "empty /api-docs-json is a loud skip" not-run 0

# error: ZAP itself broke, or the tally is missing/garbage -> scanner_error, red.
expect "zap-api-scan crash is a scanner error" error 2
expect "a missing tally is a scanner error" error 2

# safe mode: the assembled ZAP command must carry -S. Its absence is the difference
# between a passive scan and real POST/PUT/DELETE against the seeded API.
assert_zap_flag "safe mode -S is always passed" '-S'
assert_zap_flag "openapi format is passed" '-f openapi'
# the JWT reaches ZAP as a replacer rule, not the raw token in the report.
assert_zap_flag "auth is injected via a replacer rule" 'replacer.full_list(0).matchstr=Authorization'
```

`assert_zap_flag` greps the recorded `docker run … zaproxy … zap-api-scan.py` line in the shim log for a substring. Add it next to the existing assert helpers.

- [ ] **Step 2: Run the harness to confirm it fails**

Run: `./scripts/test-dast-api-scan.sh`
Expected: FAIL — `scan.sh` does not exist yet. This proves the harness runs the real script rather than passing vacuously.

- [ ] **Step 3: Write `scan.sh` — preconditions as loud skips**

Create `.github/actions/dast-api/scan.sh`. Structure, in order (full code to be written by the implementer, following `dast/scan.sh`'s helper style — `emit`, `emit_message`, `summary`, `not_run`, `scanner_error`, `cleanup`/`trap`, all copied from `dast/scan.sh` since their text is scanner-specific):

```bash
set -euo pipefail
: "${DAST_IMAGE:?}" "${ZAP_IMAGE:?}" "${DAST_REPORT_FILE:?}" "${DAST_ACTION_ROOT:?}"
. "${DAST_ACTION_ROOT}/../dast/dast-common.sh"

# generated per run, never stored, never echoed
ADMIN_USER="nova-ci-apiscan@local"
ADMIN_PASS="$(openssl rand -hex 24)"
```

Then, each failure calling `not_run` (green, loud):

1. `docker run` postgres (`ghcr.io/cloudnative-pg/postgresql:18.4-standard-trixie`) and redis (`redis:8.6.4`), wait for `pg_isready`, `CREATE EXTENSION pgcrypto` — identical to `dast/scan.sh`'s `needs-db` block.
2. `docker run -d` the engine image with the integration env plus `SWAGGER_ENABLE=true`, `NODE_ENV=production`, `DEFAULT_ADMIN_USER=$ADMIN_USER`, `DEFAULT_USER_PASSWORD` via `-e DEFAULT_USER_PASSWORD` (value from the variable, never inline in a `run:` string), `DATABASE_*` and `REDIS_*` pointing at the two containers.
3. Run `db:setup:prod` inside the engine container (`docker exec nova-app sh -c 'npm run db:setup:prod'`); a non-zero exit is `not_run "database setup failed"`.
4. Poll `http://127.0.0.1:$PORT/livez` until it answers or `DAST_BOOT_TIMEOUT`; timeout is `not_run "the image did not come up"`.
5. `curl -s -X POST …/auth/sign_in` with `{"username":"$ADMIN_USER","password":"$ADMIN_PASS"}` and `User-Agent: nova-ci-apiscan`; extract the JWT from the `Authorization` response header (or the `authentication` cookie). No JWT → `not_run "login did not return a token"`. **Never print the JWT.**
6. `curl -s …/api-docs-json` into a temp file; `jq -e '.paths | length > 0'` or `not_run "the OpenAPI spec was empty — SWAGGER_ENABLE?"`.

- [ ] **Step 4: Write `scan.sh` — the scan and the shared parse**

```bash
# -S is mandatory: without it zap-api-scan.py active-scans, i.e. real writes against the
# seeded API. -f openapi drives from the spec's real routes, not a spider (the SPA
# returns 200 for everything, so a spider is useless here). The JWT is injected on every
# request via a replacer rule so ZAP need not model the login; -config … not the token
# in a report. The triage register (-c) and the report/summary come from the same shared
# code as the baseline.
set +e
docker run --rm --network host --user "$(id -u):$(id -g)" \
    -v "$(dirname "$zap_out"):/zap/wrk:rw" "$ZAP_IMAGE" \
    zap-api-scan.py -t "$spec_url" -f openapi -S -I \
    -c "$(basename "$zap_conf")" -w "$(basename "$zap_out")" \
    -z "-config replacer.full_list(0).description=auth \
        -config replacer.full_list(0).enabled=true \
        -config replacer.full_list(0).matchtype=REQ_HEADER \
        -config replacer.full_list(0).matchstr=Authorization \
        -config replacer.full_list(0).replacement=Bearer ${JWT}" \
    2>&1 | tee "$zap_console"
zap_rc=${PIPESTATUS[0]}
set -e

case "$zap_rc" in
    0|1|2) : ;;
    *)     scanner_error "zap-api-scan.py exited ${zap_rc}" ;;
esac

zap_tally_parse "$zap_console" scanner_error
```

Then assemble the report and emit the outcome/message exactly as `dast/scan.sh` does, but titled "DAST: OWASP ZAP API scan" and mentioning the operation count. The console log holds the JWT in the replacer echo, so it is cleaned in the `trap` alongside the env file and **never** uploaded — same rule as the baseline's console log, stated in a comment.

- [ ] **Step 5: Write `action.yml`**

`.github/actions/dast-api/action.yml`, modelled on `dast/action.yml`: inputs `image`, `report-file`, `report-url`; the `ZAP_IMAGE` pin copied from `dast/action.yml` (same digest); `DAST_ACTION_ROOT: ${{ github.action_path }}`; outputs `outcome`/`findings`/`failures`/`message`. Boot timeout input defaulting to 300 (the engine's startupProbe budget, per the existing DAST core arm).

- [ ] **Step 6: Run the harness to green**

Run: `./scripts/test-dast-api-scan.sh`
Expected: PASS. Report the final count in the commit body.

- [ ] **Step 7: Prove the safe-mode guard is not vacuous**

Temporarily remove `-S` from the `zap-api-scan.py` line, run the harness, confirm `safe mode -S is always passed` fails. Restore, confirm green. This is the one flag whose absence turns a passive scan into writes against the API; its test must bite.

- [ ] **Step 8: Guard against a direct ZAP invocation**

`validate.sh` already fails if a workflow calls ZAP directly. Confirm `.github/actions/dast-api/scan.sh` invokes ZAP only through the pinned `$ZAP_IMAGE` container, never a host `zap-*` binary, and that `validate.sh`'s scanner-invocation guard covers `dast-api/` too (extend its path glob if it is scoped to `dast/`).

- [ ] **Step 9: Validate and commit**

Run: `./scripts/validate.sh` → `VALIDATION OK`.

```bash
git add .github/actions/dast-api scripts/test-dast-api-scan.sh scripts/validate.sh
git commit -m "$(cat <<'EOF'
Add the dast-api action: authenticated ZAP API scan on a seeded stack

Boots novatalks.core against ephemeral postgres and redis, runs
db:setup:prod, logs in as the seeded admin whose password this action
generates at run time and never stores, and runs zap-api-scan.py in safe
mode against the engine's own /api-docs-json.

Zero secrets: the database is ours and dies with the job, so the admin
credentials are generated here rather than kept in GitHub. Safe mode is
mandatory and has a test that bites — without -S, api-scan writes to the
seeded API. The JWT reaches ZAP through a replacer rule, and the console
log that carries it is cleaned in the trap and never uploaded.

Every precondition — postgres, migration, seed, boot, login, a non-empty
spec — is a loud skip: green build, explicit not-run, never a clean scan
of an app that was not there. Tally parse and exit ladder come from the
shared dast-common.sh.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Wire the `api-scan` job into the build workflow and the switcher

**Files:**
- Modify: `.github/workflows/ci-build-ntk-on-push-tags-build.yaml`
- Modify: `.github/workflows/ci-build-trigger-switcher.yaml`

**Interfaces:**
- Consumes: the `dast-api` action from Task 2.
- Produces: a job that runs only for `novatalks.core` on an `apiscan*` tag.

- [ ] **Step 1: Add the `api-scan` job**

In `ci-build-ntk-on-push-tags-build.yaml`, add an `api-scan` job modelled on `dast-scan`: `needs: [build-image]`, checkout `ref: ${{ github.sha }}`, install Docker, call `novaitdevteam/nova.ci/.github/actions/dast-api@main`. Gate it:

```yaml
    if: >-
      ${{ always()
      && github.event_name != 'pull_request'
      && needs.build-image.result == 'success'
      && github.event.repository.name == 'novatalks.core'
      && startsWith(github.ref_name, 'apiscan') }}
```

Reuse the same `RELEASE_TAG` / report-upload / release-publish steps as `dast-scan`, so the API report lands on the same `TRIVY.SCAN_*` release. Report file `zap-api-<REP_NAME>-<REF>-<SHA>.report`.

- [ ] **Step 2: Add the notifier compose step**

Copy the `Compose DAST line` step to `Compose API-scan line`, reading `needs.api-scan.outputs`. Same four-state shape (skipped / message / failed-before-reporting). Add its output to the notifier body assembly.

- [ ] **Step 3: Route `apiscan*` tags in the switcher**

In `ci-build-trigger-switcher.yaml`, the `call-external-on-push-tags` job's `if` already matches `startsWith(github.ref_name, 'scan')`. Add `|| startsWith(github.ref_name, 'apiscan')` so an `apiscan*` tag reaches the build workflow. Confirm `apiscan` does not also match the `scan` prefix in a way that double-fires — `apiscan` does not start with `scan`, so it does not; note this explicitly in the diff.

- [ ] **Step 4: Normalise the build target for `apiscan` tags**

`novatalks.core`'s `scan*` tags normalise `BUILD_TARGET` to `build-engine` (so a scan tag builds the engine image). An `apiscan*` tag needs the same — the API scan needs the engine image. Extend the existing normalisation:

```bash
if [[ "$REPO_NAME" == "novatalks.core" && ( "$BUILD_TARGET" == scan* || "$BUILD_TARGET" == apiscan* ) ]]; then
  BUILD_TARGET="build-engine"
fi
```

- [ ] **Step 5: Runner sizing**

The API-scan stack is postgres + redis + engine + ZAP on one VM — the same shape `medium` already covers for core's DAST. Confirm `ci-build-create-runner.sh` sizes an `apiscan*` core build `medium`, extending the existing `scan*`/trunk branch if it keys on `scan` specifically. Add a scenario to `scripts/test-create-runner.sh` for an `apiscan` tag → `medium`.

- [ ] **Step 6: Validate and commit**

Run: `./scripts/validate.sh` → `VALIDATION OK`, and `./scripts/test-create-runner.sh`.

```bash
git add .github/workflows/ci-build-ntk-on-push-tags-build.yaml .github/workflows/ci-build-trigger-switcher.yaml .github/workflows/ci-build-create-runner.sh scripts/test-create-runner.sh
git commit -m "$(cat <<'EOF'
Route apiscan* tags to a novatalks.core API-scan job

A new job runs the dast-api action for novatalks.core on an apiscan* tag
only — not per build, because a 341-operation scan is an opt-in cost. It
builds the engine image (same BUILD_TARGET normalisation as scan* tags),
runs on a medium runner (postgres + redis + engine + ZAP, the load
medium already exists for), and publishes its report to the same
TRIVY.SCAN_ release as the other scanners.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: The live-instance baseline workflow

**Files:**
- Create: `.github/workflows/ci-dast-live-baseline.yaml`

**Interfaces:**
- Consumes: the existing `dast` action is image-based and cannot target a URL, so this workflow calls `zap-baseline.py` through a small inline step reusing `dast-common.sh` for the parse. Alternatively, factor the URL-target path into the `dast` action via a `target-url` input — decide in Step 1.

- [ ] **Step 1: Decide the target mechanism, and record the decision**

The `dast` action boots an image; the live baseline scans a URL. Two options, pick one and write the choice into the workflow as a comment:
- **(a)** a `target-url` input on the `dast` action that, when set, skips the boot and points ZAP at the URL. Reuses the report/tally path, but complicates the action with a mode it mostly does not use.
- **(b)** an inline step in this workflow that runs the pinned `$ZAP_IMAGE` `zap-baseline.py -t <url>` and sources `dast-common.sh` for the parse.

Prefer **(b)**: the live baseline is a `workflow_dispatch` one-off with no image boot, no env seeding, no database — almost none of the `dast` action applies, and bending the action to fit is more surface than an inline step. The shared parse still comes from `dast-common.sh`, so the drift-dangerous logic is not copied.

- [ ] **Step 2: Write the workflow with an allowlisted target**

`.github/workflows/ci-dast-live-baseline.yaml`, `on: workflow_dispatch` with a `target` input. First step validates:

```bash
case "$TARGET" in
  https://novatalks-security.cloud.novatalks.com.ua|https://novatalks-security.cloud.novatalks.com.ua/) : ;;
  *) echo "::error::'$TARGET' is not an allowlisted DAST target. Add it here deliberately."; exit 1 ;;
esac
```

Then `docker run` the pinned ZAP image with `zap-baseline.py -t "$TARGET" -I -c zap-baseline.conf -w report.md`, source `dast-common.sh`, parse, and publish the report as a workflow artifact (no release — this is not tied to a build). Runner `ubuntu-latest`: it is public and needs no self-hosted runner. `permissions: contents: read`.

- [ ] **Step 3: State the SPA-200 caveat in the report header**

The report's header must say that this host returns 200 for every path (SPA behind nginx), so the spider walks invented routes and header findings appear duplicated — volume is not coverage. This is D7 of the spec; a reader who does not know it will misread the count.

- [ ] **Step 4: Validate and commit**

`./scripts/validate.sh` must still pass, including its self-reference-pin and scanner-invocation guards — the inline ZAP call goes through `$ZAP_IMAGE`, and the workflow references no nova.ci ref other than the action paths it uses (if any). If `validate.sh`'s "no workflow runs ZAP directly" guard flags the inline `zap-baseline.py`, that guard is about *product* workflows; extend its allowance for this meta-workflow the same way `ci-self-validate.yaml` is handled, and record why in the guard's comment.

```bash
git add .github/workflows/ci-dast-live-baseline.yaml scripts/validate.sh
git commit -m "$(cat <<'EOF'
Add a workflow_dispatch baseline of the live instance

Scans the real deployment through Cloudflare, which the container DAST
cannot see: on the live host nginx serves the SPA with none of the
security headers helmet adds on the engine's own routes. Unauthenticated —
the value is the header surface, which needs no login.

Target is validated against a one-host allowlist; anything else fails
loudly. A free-text URL with no allowlist is how a scanner eventually
points somewhere it must not. Runs on ubuntu-latest, no secrets, report as
a workflow artifact. The report header states that this SPA returns 200
for every path, so duplicate header findings are not extra coverage.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Documentation, invariants and skill mirrors

**Files:**
- Modify: `docs/sast-dast.md`
- Modify: `CLAUDE.md`
- Modify: `.agents/skills/nova-ci/SKILL.md`, `.claude/skills/nova-ci/SKILL.md`

- [ ] **Step 1: Document A and B in `docs/sast-dast.md`**

A new section: what api-scan is (authenticated, safe-mode, spec-driven), that it runs on an `apiscan*` tag for `novatalks.core` only, that credentials are generated per run and never stored, and the honest reach — passive checks across real endpoints, not IDOR / privilege / business-logic, and not a pentest. A shorter section for the live baseline: what it catches (nginx/ingress headers), how to run it, the allowlist, and the SPA-200 caveat. Both open under the page's existing asset — check the diagram does not now lie about scanner count; regenerate only if it does.

- [ ] **Step 2: Add invariants to `CLAUDE.md`**

Under Code scanning:
- The `apiscan*` job runs `zap-api-scan.py` in **safe mode** always; dropping `-S` turns a passive scan into real writes against the seeded API. The harness asserts `-S` is passed.
- The seeded admin's password is generated per run and never stored; `DEFAULT_ADMIN_USER`/`DEFAULT_USER_PASSWORD` set it. The engine needs `SWAGGER_ENABLE=true` or `/api-docs-json` is empty and the scan is a loud skip.
- The tally parse, anchor and numeric guard live in `dast-common.sh` and are sourced by both `dast` and `dast-api`; do not re-inline or copy them — the ANSI-C `\t` and the shape-not-prefix anchor are why.
- The live-baseline workflow validates its target against an allowlist; adding a host is a deliberate edit.

- [ ] **Step 2b: Fix the stale harness counts in `CLAUDE.md`**

Update the check counts to what the harnesses print after this branch (DAST 112 unchanged, new `test-dast-api-scan.sh` count, `test-create-runner.sh` +1).

- [ ] **Step 3: Mirror both SKILL.md files**

Apply the same additions to `.agents/skills/nova-ci/SKILL.md` and `cp` to the `.claude` mirror. `validate.sh` fails if they diverge.

- [ ] **Step 4: Validate and commit**

`./scripts/validate.sh` → `VALIDATION OK`, including the mirror check.

```bash
git add docs/sast-dast.md CLAUDE.md .agents/skills/nova-ci/SKILL.md .claude/skills/nova-ci/SKILL.md
git commit -m "$(cat <<'EOF'
Document API scanning, the live baseline, and their invariants

Records the safe-mode requirement, the generated-not-stored credentials,
the SWAGGER_ENABLE precondition, the shared dast-common.sh, and the target
allowlist. States the honest reach plainly: passive checks across real
endpoints, not a pentest, not logic flaws.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Verification before the pull request

- [ ] `./scripts/validate.sh` ends `VALIDATION OK`
- [ ] All harnesses green — DAST 112, the new api-scan harness, create-runner, under BSD and GNU grep
- [ ] `git log --format='%(trailers:key=Co-Authored-By)' main..` shows a trailer on every commit
- [ ] No credential value appears in any committed file (grep the diff for the generated-password pattern; it must only ever be a variable reference)
- [ ] No product repository was modified
- [ ] A live `apiscan-test` tag run on `novatalks.core` confirms A2 — that the seeded stack boots, login succeeds, the spec loads, and `zap-api-scan.py`'s tally prints in the shape `zap_tally_parse` expects. This is the assumption the whole branch rests on; the guard fails closed if it is wrong, but the first real run is where it is confirmed.
- [ ] B is verified against the live instance **only after the leaked credentials are rotated** — the target is the same host whose admin session was exposed.
