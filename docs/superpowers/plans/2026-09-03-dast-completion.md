# DAST Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every one of eight repositories produces a real DAST verdict instead of `⚠️ not run`, and an active (attacking) ZAP scan covers both the API and the browser surface on manual dispatch.

**Architecture:** Two new `scan-mode` switches on the two existing composite actions rather than a third and fourth action; one shared per-repository target table replacing what would otherwise be three divergent `case` statements; one new manual workflow in `nova.ci` that runs on `ubuntu-latest` and costs no Hetzner runner.

**Tech Stack:** Bash, GitHub Actions composite actions and reusable workflows, Docker, OWASP ZAP (`zap-baseline.py`, `zap-api-scan.py`, `zap-full-scan.py`), PostgreSQL, `jq`.

**Spec:** [`docs/superpowers/specs/2026-09-03-dast-completion-design.md`](../specs/2026-09-03-dast-completion-design.md)

## Global Constraints

Copied verbatim from `CLAUDE.md` and the spec. Every task's requirements implicitly include this section.

- **A scanner that could not run is never reported clean.** Every mode added here carries a positive proof that it ran as configured, and every such proof gets a mutation test that fails when the proof is removed.
- **`warn-only` governs findings. A scanner that could not run reds the job. Never collapse the two.**
- **An application that fails to boot is a loud skip** — green build, explicit `⚠️ not run — <reason>` in the report, the job summary and the notification. Never silence it, never red it.
- **Keep Semgrep and the ZAP image pinned by tag AND digest, never `latest`.** The pin in use is `ghcr.io/zaproxy/zaproxy:stable@sha256:781a2bdaea47324e7bab583e2263f21d257b0aee61ed51521a5be45f5f5081ef`. It appears in `dast/action.yml`, `dast-api/action.yml` and `ci-dast-live-baseline.yaml`; a new caller copies that exact string.
- **The tally-line anchor, `tally_at` and the numeric guard live in `.github/actions/dast/dast-common.sh`** and are sourced by every ZAP caller. Never re-inline or copy them.
- **Keep `0|1|2` in the ZAP exit-code `case`.** Exit 1 is `FAIL`-level findings and `-I` does not suppress it. Exit 3 is an exception or a scan that ran no checks — that is the error arm.
- **Changing `.github/actions/dast/scan.sh` means adding a scenario to `scripts/test-dast-scan.sh` in the same change**; likewise `dast-api/scan.sh` and `scripts/test-dast-api-scan.sh`.
- **No workflow may invoke ZAP directly**; `scripts/validate.sh` fails on it. Everything goes through a composite action or, for the two standalone `nova.ci` workflows, an inline step that sources `dast-common.sh`.
- **Never print a credential value.** Tokens and generated passwords are `::add-mask::`ed before any container output is printed.
- **Per-repository values are read from that repository's own code** — the Dockerfile, the guard, the schema, the chart — never inferred from a sibling. This is spec D5 and it is not negotiable: guessing has already cost two failed live runs.
- Run `./scripts/validate.sh` after any workflow, action or documentation change. It must print `VALIDATION OK`.
- Documentation sync is part of the task, not a follow-up: `docs/sast-dast.md`, `CLAUDE.md` when an invariant changes, and **both** `.agents/skills/nova-ci/SKILL.md` and `.claude/skills/nova-ci/SKILL.md` (byte-identical; `validate.sh` fails if they diverge).

---

## File Structure

**Created:**

| File | Responsibility |
| --- | --- |
| `.github/actions/dast/targets.sh` | The single per-repository DAST table. One function, `dast_resolve_target <repo> <surface>`, sets `DT_*` variables in the caller's scope. Sourced by every consumer so the table exists exactly once. |
| `.github/actions/dast/zap-full-scan.conf` | Triage register for the active scanner. |
| `.github/workflows/ci-dast-pentest.yaml` | Manual active scan. `workflow_dispatch` only, `ubuntu-latest`. |
| `scripts/test-dast-targets.sh` | Offline self-check for the target table. |

**Modified:**

| File | Change |
| --- | --- |
| `.github/actions/dast/action.yml` | New `scan-mode` input, passed as `DAST_SCAN_MODE`. |
| `.github/actions/dast/scan.sh` | `scan-mode` fork: script name, `-j`, register, timeout. |
| `.github/actions/dast-api/action.yml` | New `scan-mode` input, passed as `DAST_API_SCAN_MODE`. |
| `.github/actions/dast-api/scan.sh` | `scan-mode` fork (`-S`); two new auth modes. |
| `.github/workflows/ci-build-ntk-on-push-tags-build.yaml` | Both `Resolve …` steps source `targets.sh` instead of carrying their own `case`. |
| `scripts/test-dast-scan.sh`, `scripts/test-dast-api-scan.sh` | Scenarios for every new fork, each mutation-checked. |

---

### Task 1: One target table, three consumers

Extracting the per-repository table **first** is what stops this plan from creating a third and fourth copy of it. Pure refactor: no behaviour change, proven by the existing harnesses still passing unchanged.

**Files:**
- Create: `.github/actions/dast/targets.sh`
- Create: `scripts/test-dast-targets.sh`
- Modify: `.github/workflows/ci-build-ntk-on-push-tags-build.yaml` (the `Resolve DAST target` and `Resolve api-scan target` steps)
- Modify: `scripts/validate.sh` (run the new harness)

**Interfaces:**
- Produces: `dast_resolve_target <repo> <surface>` where `<surface>` is `api` or `browser`. On success it sets, in the caller's scope: `DT_PORT`, `DT_HEALTH_PATH`, `DT_SPEC_PATH`, `DT_NEEDS_DB`, `DT_NEEDS_NATS`, `DT_AUTH_MODE`, `DT_LOGIN_PATH`, `DT_AUTH_HEADER`, `DT_AUTH_SCHEME_PREFIX`, `DT_TOKEN_SQL`, `DT_TOKEN_INSERT_SQL`, `DT_TOKEN_ENV_VAR`, `DT_SETUP_COMMAND`, `DT_SWAGGER_ENABLE`, `DT_EXTRA_ENV`, `DT_ZAP_CONTEXT`. On an unknown pair it prints `::error::` and returns 1.
  - The full set is declared here even though `DT_TOKEN_INSERT_SQL` (Task 4), `DT_TOKEN_ENV_VAR` (Task 5) and `DT_ZAP_CONTEXT` (Task 9) have no consumer yet. The table's shape is fixed once, so a later task adds a *value*, never a variable — and every arm resets every key, so an unset field can never leak from the previous caller.
  - `DT_AUTH_MODE` values: `login`, `db-token`, `db-insert`, `env-token`, `none`. `none` means the repository has no authentication at all; the scan runs unauthenticated and the report says so.
- Consumes: nothing.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-dast-targets.sh`:

```bash
#!/usr/bin/env bash
#
# Self-check for .github/actions/dast/targets.sh — the single per-repository DAST table.
#
# The table decides where every scanner points and how it authenticates. A wrong value
# here is not a crash: it is a scan of the wrong port that finds nothing and reports it
# clean. So the shape of every arm is asserted, and the default arm is asserted to fail.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../.github/actions/dast/targets.sh
. "$ROOT/.github/actions/dast/targets.sh"

pass=0
fail=0

check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "ok   $1"; pass=$((pass + 1))
    else
        echo "FAIL $1 — expected '$2', got '$3'"; fail=$((fail + 1))
    fi
}

reset_dt() { unset "${!DT_@}"; }

# novatalks.core, browser surface: the values the build workflow has always used.
reset_dt; dast_resolve_target novatalks.core browser
check "core/browser port"        3000     "$DT_PORT"
check "core/browser health"      /livez   "$DT_HEALTH_PATH"
check "core/browser needs a db"  true     "$DT_NEEDS_DB"

# novatalks.core, api surface: same image, different scanner, JWT login.
reset_dt; dast_resolve_target novatalks.core api
check "core/api auth mode"       login              "$DT_AUTH_MODE"
check "core/api login path"      /auth/sign_in      "$DT_LOGIN_PATH"
check "core/api header"          Authorization      "$DT_AUTH_HEADER"
check "core/api prefix"          "Bearer "          "$DT_AUTH_SCHEME_PREFIX"
check "core/api spec path"       /api-docs-json     "$DT_SPEC_PATH"
# Empty on purpose: the runtime image ships no npm and its entrypoint migrates and seeds.
check "core/api setup command"   ""                 "$DT_SETUP_COMMAND"

# The telegram connector: a DB-backed token under its own header, no scheme prefix.
reset_dt; dast_resolve_target nova.chatsconnector.telegram-client-api api
check "telegram auth mode"       db-token           "$DT_AUTH_MODE"
check "telegram header"          api_access_token   "$DT_AUTH_HEADER"
check "telegram prefix is empty" ""                 "$DT_AUTH_SCHEME_PREFIX"
check "telegram health path"     /                  "$DT_HEALTH_PATH"

# nova.botflow has no HTTP health route; "/" is correct and must not be "fixed".
reset_dt; dast_resolve_target nova.botflow browser
check "botflow port"             1880     "$DT_PORT"
check "botflow health"           /        "$DT_HEALTH_PATH"

# A guessed target scans the wrong port and reports it clean, so an unknown pair must
# fail loudly rather than fall through to a default.
reset_dt
if dast_resolve_target no.such.repo api >/dev/null 2>&1; then
    echo "FAIL an unknown repository resolved instead of failing"; fail=$((fail + 1))
else
    echo "ok   an unknown repository fails loudly"; pass=$((pass + 1))
fi

# A repository with no browser surface must not silently answer for one.
reset_dt
if dast_resolve_target nova.chatsconnector.telegram-client-api browser >/dev/null 2>&1; then
    echo "FAIL a headless connector resolved a browser surface"; fail=$((fail + 1))
else
    echo "ok   a headless connector has no browser surface"; pass=$((pass + 1))
fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

```bash
chmod +x scripts/test-dast-targets.sh && ./scripts/test-dast-targets.sh
```

Expected: FAIL — `.github/actions/dast/targets.sh: No such file or directory`.

- [ ] **Step 3: Write `targets.sh`**

Move the values verbatim out of the two `case` statements in `ci-build-ntk-on-push-tags-build.yaml`. Do not retype them from memory and do not "tidy" them — the comments explaining *why* a value is what it is travel with the value.

```bash
#!/usr/bin/env bash
#
# The one per-repository DAST table.
#
# Sourced by every consumer, because there are now three and copies drift:
#   ci-build-ntk-on-push-tags-build.yaml  "Resolve DAST target"      (browser)
#   ci-build-ntk-on-push-tags-build.yaml  "Resolve api-scan target"  (api)
#   ci-dast-pentest.yaml                  (either)
#
# Every value here is read from the repository it describes — its Dockerfile, its guard,
# its schema, its Helm chart — never inferred from a sibling. A guessed port does not
# crash: it scans nothing and reports it clean.
#
# dast_resolve_target <repo> <surface:api|browser>
#   Sets DT_* in the caller's scope. Returns 1 on an unknown repository/surface pair,
#   after an ::error:: — the default arm never guesses.

dast_resolve_target() {
    local repo="$1" surface="$2"

    DT_PORT=""; DT_HEALTH_PATH=""; DT_SPEC_PATH=""
    DT_NEEDS_DB=false; DT_NEEDS_NATS=false
    DT_AUTH_MODE=""; DT_LOGIN_PATH=""; DT_AUTH_HEADER=""; DT_AUTH_SCHEME_PREFIX=""
    DT_TOKEN_SQL=""; DT_TOKEN_INSERT_SQL=""; DT_TOKEN_ENV_VAR=""
    DT_SETUP_COMMAND=""; DT_SWAGGER_ENABLE=false; DT_EXTRA_ENV=""; DT_ZAP_CONTEXT=""

    case "${repo}/${surface}" in
        novatalks.ui/browser)
            # nginx serving the static Vue app. Port and health path from the production
            # Helm chart (novatalks.charts, novatalks_v5/values.yaml) — authoritative
            # because it is what runs in prod.
            DT_PORT=8000; DT_HEALTH_PATH=/livez
            ;;
        novatalks.core/browser)
            # NestJS engine. Same chart source as above.
            DT_PORT=3000; DT_HEALTH_PATH=/livez; DT_NEEDS_DB=true
            ;;
        nova.botflow/browser)
            # No dedicated HTTP health route — the chart probes over tcpSocket. "/" is
            # correct: the boot wait-loop accepts any HTTP response, 404 included, because
            # it tests whether the process is listening, not whether a route exists.
            # Do not "fix" this to /livez.
            DT_PORT=1880; DT_HEALTH_PATH=/; DT_NEEDS_DB=true
            ;;
        novatalks.core/api)
            DT_PORT=3000; DT_HEALTH_PATH=/livez; DT_SPEC_PATH=/api-docs-json
            DT_NEEDS_DB=true
            DT_AUTH_MODE=login; DT_LOGIN_PATH=/auth/sign_in
            DT_AUTH_HEADER=Authorization; DT_AUTH_SCHEME_PREFIX='Bearer '
            DT_SWAGGER_ENABLE=true
            # No setup command: docker/engine.Dockerfile's runtime stage installs
            # nodejs-24 and not npm, and its entrypoint.sh already runs create-database,
            # sequelize db:migrate and seed-database with plain `node` before the app
            # serves anything.
            DT_SETUP_COMMAND=''
            ;;
        nova.chatsconnector.telegram-client-api/api)
            # api_access_token header (setup-swagger.ts), DB-backed token in
            # tokens.api_token joined to token_roles.role (schema.prisma), seeded by the
            # image's own entrypoint, Swagger served unconditionally, no health route.
            DT_PORT=3000; DT_HEALTH_PATH=/; DT_SPEC_PATH=/api-docs-json
            DT_NEEDS_DB=true
            DT_AUTH_MODE=db-token
            DT_AUTH_HEADER=api_access_token; DT_AUTH_SCHEME_PREFIX=''
            DT_TOKEN_SQL="SELECT t.api_token FROM tokens t JOIN token_roles r ON t.role_id = r.id WHERE r.role = 'SUPER_ADMIN' ORDER BY t.id LIMIT 1;"
            DT_SETUP_COMMAND=''
            DT_SWAGGER_ENABLE=false
            # Boot dummies the connector's config validator rejects a blank for.
            DT_EXTRA_ENV='TELEGRAM_API_ID=12345
TELEGRAM_API_HASH=00000000000000000000000000000000
NOVATALKS_ACCESS_TOKEN=dast-dummy-dummy-token
ENCRYPTION_SECRET=dast-dummy-dummy-dummy-dummy-dummy'
            ;;
        *)
            echo "::error::No DAST configuration for '${repo}' on the '${surface}' surface. Add an arm with its port, health path and auth read from that repository's own code — a guessed value scans nothing and reports it clean."
            return 1
            ;;
    esac
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
./scripts/test-dast-targets.sh
```

Expected: `--- 13 passed, 0 failed`.

- [ ] **Step 5: Switch both workflow steps to the shared table**

In `ci-build-ntk-on-push-tags-build.yaml`, replace the body of `Resolve DAST target` with:

```yaml
        run: |
          set -euo pipefail
          # shellcheck source=.github/actions/dast/targets.sh
          . "${GITHUB_WORKSPACE}/.github/actions/dast/targets.sh"
          dast_resolve_target "$REPO_NAME" browser

          echo "port=$DT_PORT" | tee -a "$GITHUB_OUTPUT"
          echo "health_path=$DT_HEALTH_PATH" | tee -a "$GITHUB_OUTPUT"
          echo "needs_db=$DT_NEEDS_DB" | tee -a "$GITHUB_OUTPUT"
          echo "needs_nats=$DT_NEEDS_NATS" | tee -a "$GITHUB_OUTPUT"
          {
            echo "extra_env<<DAST_EXTRA_ENV_EOF"
            printf '%s\n' "$DT_EXTRA_ENV"
            echo "DAST_EXTRA_ENV_EOF"
          } >> "$GITHUB_OUTPUT"
```

Do the same for `Resolve api-scan target`, passing `api` and emitting the api keys it already emits. Keep every heredoc-delimited output exactly as it is — `auth_scheme_prefix` carries a trailing space and `token_sql`/`extra_env` are multi-line.

The `dast-scan` job needs a `Checkout` step before `Resolve DAST target` if it does not already have one, because `targets.sh` is read from `$GITHUB_WORKSPACE`. Verify this: `grep -n 'Checkout' -A3 -B20 'Resolve DAST target'`.

- [ ] **Step 6: Wire the harness into `validate.sh`**

Add, beside the other self-checks:

```bash
echo "=== DAST target table self-check ==="
"$ROOT/scripts/test-dast-targets.sh"
```

- [ ] **Step 7: Verify nothing changed**

```bash
./scripts/validate.sh
```

Expected: `VALIDATION OK`, with `test-dast-scan.sh` and `test-dast-api-scan.sh` passing **unchanged** — that is the proof this task was a pure extraction.

- [ ] **Step 8: Commit**

```bash
git add .github/actions/dast/targets.sh scripts/test-dast-targets.sh scripts/validate.sh \
        .github/workflows/ci-build-ntk-on-push-tags-build.yaml
git commit -m "Give the per-repository DAST table one home before it gets a third copy"
```

---

### Task 2: `scan-mode` on `dast-api` — drop `-S` and attack

**Files:**
- Modify: `.github/actions/dast-api/action.yml`
- Modify: `.github/actions/dast-api/scan.sh`
- Test: `scripts/test-dast-api-scan.sh`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `scan-mode` input on `dast-api/action.yml`, values `passive` (default) and `active`, reaching `scan.sh` as `DAST_API_SCAN_MODE`.

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test-dast-api-scan.sh`, before the final `echo "--- $pass passed"`:

```bash
# --- active mode: -S comes off, and that is the whole difference --------------------
# -S is safe mode. With it, zap-api-scan.py only observes; without it, it sends real
# POST/PUT/DELETE and injection payloads. That is the entire point of an active scan and
# also the single most dangerous flag in this repository, so both directions are pinned.
DAST_API_SCAN_MODE=active SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "active mode still reports a clean scan" clean 0
if grep -E 'zap-api-scan\.py' "$WORK/dockerlog" | grep -qE '(^| )-S( |$)'; then
    echo "FAIL active mode kept -S — it would still be a passive scan reported as active"
    fail=$((fail + 1))
else
    echo "ok   active mode drops -S"; pass=$((pass + 1))
fi

# Passive stays the default: nobody gets an attacking scan by omitting an input.
unset DAST_API_SCAN_MODE
SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "the default is still passive" clean 0
assert_zap_flag "an unset scan-mode keeps -S" '-S'

# An unrecognised mode is a broken configuration, not a silent fallback to either one.
DAST_API_SCAN_MODE=aggressive expect "an unknown scan-mode is a scanner error" error 2
```

- [ ] **Step 2: Run to verify they fail**

```bash
./scripts/test-dast-api-scan.sh
```

Expected: `FAIL active mode kept -S`, and the unknown-mode scenario reports `outcome=clean` where `error` was wanted.

- [ ] **Step 3: Implement the fork**

In `.github/actions/dast-api/scan.sh`, above the `docker run` that invokes `zap-api-scan.py`:

```bash
# -S is safe mode: passive observation only. Dropping it turns this into an active scan
# that sends real POST/PUT/DELETE and injection payloads against the seeded API using the
# session this script just created. That is safe here and nowhere else — the database is
# ours, it was created seconds ago and it dies with this job — but it is the most
# dangerous flag in this repository, so it is an explicit mode, never a default.
zap_mode_args=()
case "${DAST_API_SCAN_MODE:-passive}" in
    passive) zap_mode_args+=(-S) ;;
    active)  : ;;
    *) scanner_error "unknown scan-mode: ${DAST_API_SCAN_MODE}" ;;
esac
```

Then replace `-S` in the invocation with `"${zap_mode_args[@]+"${zap_mode_args[@]}"}"`:

```bash
    zap-api-scan.py -t "$spec_url" -f openapi \
    ${zap_mode_args[@]+"${zap_mode_args[@]}"} -I \
```

Add to `.github/actions/dast-api/action.yml`:

```yaml
  scan-mode:
    description: "passive (default) observes only, via zap-api-scan.py's -S safe mode. active drops -S and sends real POST/PUT/DELETE and injection payloads — only ever against the ephemeral stack this action starts and kills."
    required: false
    default: "passive"
```

and in the step's `env:`:

```yaml
        DAST_API_SCAN_MODE: ${{ inputs.scan-mode }}
```

- [ ] **Step 4: Run to verify they pass**

```bash
./scripts/test-dast-api-scan.sh
```

Expected: all scenarios pass, count up by 4.

- [ ] **Step 5: Mutation-check the guard**

```bash
cp .github/actions/dast-api/scan.sh /tmp/m.bak
sed -i '' 's/    active)  : ;;/    active)  zap_mode_args+=(-S) ;;/' .github/actions/dast-api/scan.sh
./scripts/test-dast-api-scan.sh; cp /tmp/m.bak .github/actions/dast-api/scan.sh
```

Expected: `FAIL active mode kept -S`. If it passes, the assertion is not testing what it claims and must be fixed before continuing.

- [ ] **Step 6: Validate, document and commit**

Update `docs/sast-dast.md` (the API scanning section) and the `-S` invariant in `CLAUDE.md` — it currently says `-S` is passed *always*, which stops being true here. Mirror into both `SKILL.md` files.

```bash
./scripts/validate.sh
git add -A && git commit -m "Add an active scan-mode to dast-api: -S comes off, deliberately"
```

---

### Task 3: `scan-mode` on `dast` — `zap-full-scan.py` and the modern spider

**Files:**
- Create: `.github/actions/dast/zap-full-scan.conf`
- Modify: `.github/actions/dast/action.yml`
- Modify: `.github/actions/dast/scan.sh`
- Test: `scripts/test-dast-scan.sh`

**Interfaces:**
- Produces: `scan-mode` input on `dast/action.yml`, values `baseline` (default) and `full`, reaching `scan.sh` as `DAST_SCAN_MODE`.

**Verified upstream facts this task depends on** — do not re-derive, and do not assume beyond them: `zap-full-scan.py` accepts `-t -c -w -I -j -m -T -n -U -z`; it prints the identical tally line (`FAIL-NEW: n\tFAIL-INPROG: …`, `zap-full-scan.py:480`); its exit ladder is identical (`0` passes only, `1` FAIL findings, `2` warnings without `-I`, `3` exception or nothing ran). Therefore `dast-common.sh` needs no change and the existing exit `case` needs no change.

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test-dast-scan.sh`:

```bash
# --- full mode: a different script, a different spider, a different register ---------
# zap-baseline.py has no active scanner at all. zap-full-scan.py does, and -j swaps the
# traditional spider for the modern one, which is the only way a single-page app is more
# than one page to ZAP.
DAST_SCAN_MODE=full SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "full mode reports a clean scan" clean 0
if grep -q "zap-full-scan.py" "$WORK/dockerlog"; then
    echo "ok   full mode runs zap-full-scan.py"; pass=$((pass + 1))
else
    echo "FAIL full mode still ran the baseline script"; fail=$((fail + 1))
fi
if grep -E 'zap-full-scan\.py' "$WORK/dockerlog" | grep -qE '(^| )-j( |$)'; then
    echo "ok   full mode uses the modern spider"; pass=$((pass + 1))
else
    echo "FAIL full mode has no -j — a SPA would still be one page"; fail=$((fail + 1))
fi
if grep -q "zap-full-scan.conf" "$WORK/dockerlog"; then
    echo "ok   full mode loads its own triage register"; pass=$((pass + 1))
else
    echo "FAIL full mode reused the baseline register"; fail=$((fail + 1))
fi

# Baseline stays the default, and stays free of -j: the traditional spider is what the
# baseline's finding counts have always been measured with.
unset DAST_SCAN_MODE
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "the default is still the baseline" clean 0
if grep -q "zap-baseline.py" "$WORK/dockerlog"; then
    echo "ok   an unset scan-mode runs zap-baseline.py"; pass=$((pass + 1))
else
    echo "FAIL the default changed"; fail=$((fail + 1))
fi

DAST_SCAN_MODE=deep expect "an unknown scan-mode is a scanner error" error 2
```

- [ ] **Step 2: Run to verify they fail**

```bash
./scripts/test-dast-scan.sh
```

Expected: four new failures.

- [ ] **Step 3: Create the triage register**

`.github/actions/dast/zap-full-scan.conf` — copy `zap-baseline.conf` verbatim, then change its first line to `# nova.ci — OWASP ZAP active (full) scan triage register` and replace the "generate the rule list" snippet's command with:

```
#   docker run --rm -v "$PWD:/zap/wrk:rw" ghcr.io/zaproxy/zaproxy:stable \
#       zap-full-scan.py -t http://example.com -g zap-rules.conf
```

Add one paragraph explaining why it is its own file:

```
# Separate from zap-baseline.conf because the active scanner loads the whole active rule
# set on top of the passive one — injection, traversal, command execution — rules the
# baseline never reaches. A register written for one is not a register for the other, and
# an IGNORE carried across would silence a class of finding nobody agreed to accept.
```

Keep it empty of entries. An entry is a risk-acceptance decision, not a CI change.

- [ ] **Step 4: Implement the fork**

In `.github/actions/dast/scan.sh`, where `zap_conf_src` is set, replace the fixed name with the mode's:

```bash
# baseline observes; full attacks. Two scripts, two spiders, two registers — and the
# exit ladder and tally line are identical between them, verified against
# zap-full-scan.py:480 and :511-522, which is why dast-common.sh is untouched.
case "${DAST_SCAN_MODE:-baseline}" in
    baseline)
        zap_script=zap-baseline.py
        zap_conf_name=zap-baseline.conf
        zap_mode_args=()
        ;;
    full)
        zap_script=zap-full-scan.py
        zap_conf_name=zap-full-scan.conf
        # -j swaps the traditional spider for the modern one. Without it a single-page
        # app is exactly one page to ZAP: nginx serves index.html for every route and the
        # traditional spider has no JavaScript to follow.
        zap_mode_args=(-j)
        ;;
    *) scanner_error "unknown scan-mode: ${DAST_SCAN_MODE}" ;;
esac
zap_conf_src="${DAST_ACTION_ROOT}/${zap_conf_name}"
zap_conf="${RUNNER_TEMP:-/tmp}/${zap_conf_name}"
```

Then in the invocation, replace `zap-baseline.py` with `"$zap_script"` and add the mode args:

```bash
    "$ZAP_IMAGE" "$zap_script" -t "$target" \
    ${zap_mode_args[@]+"${zap_mode_args[@]}"} \
    -I -c "$(basename "$zap_conf")" -w "$(basename "$zap_out")" 2>&1 | tee "$zap_console"
```

Add to `action.yml`:

```yaml
  scan-mode:
    description: "baseline (default) runs zap-baseline.py — passive, traditional spider. full runs zap-full-scan.py with the modern spider (-j) and the active rule set, which sends real attack payloads; only ever against the ephemeral container this action starts and kills."
    required: false
    default: "baseline"
```

and `DAST_SCAN_MODE: ${{ inputs.scan-mode }}` to the step's `env:`.

- [ ] **Step 5: Run to verify they pass**

```bash
./scripts/test-dast-scan.sh
```

Expected: all pass, count up by 6.

- [ ] **Step 6: Mutation-check each of the three assertions**

```bash
cp .github/actions/dast/scan.sh /tmp/m.bak
# the spider
sed -i '' 's/        zap_mode_args=(-j)/        zap_mode_args=()/' .github/actions/dast/scan.sh
./scripts/test-dast-scan.sh; cp /tmp/m.bak .github/actions/dast/scan.sh
# the register
sed -i '' 's/        zap_conf_name=zap-full-scan.conf/        zap_conf_name=zap-baseline.conf/' .github/actions/dast/scan.sh
./scripts/test-dast-scan.sh; cp /tmp/m.bak .github/actions/dast/scan.sh
# the script
sed -i '' 's/        zap_script=zap-full-scan.py/        zap_script=zap-baseline.py/' .github/actions/dast/scan.sh
./scripts/test-dast-scan.sh; cp /tmp/m.bak .github/actions/dast/scan.sh
```

Expected: one distinct failure per mutation. Restore after each.

- [ ] **Step 7: Validate, document, commit**

```bash
./scripts/validate.sh
git add -A && git commit -m "Add a full scan-mode to dast: the active rule set and the modern spider"
```

---

### Task 4: `db-insert` auth mode — for images whose seeder was pruned away

**Files:**
- Modify: `.github/actions/dast-api/action.yml`
- Modify: `.github/actions/dast-api/scan.sh`
- Test: `scripts/test-dast-api-scan.sh`

**Interfaces:**
- Consumes: the `DAST_AUTH_MODE` fork already in `dast-api/scan.sh` (`login`, `db-token`).
- Produces: a third value, `db-insert`, driven by a new `token-insert-sql` input reaching `scan.sh` as `DAST_TOKEN_INSERT_SQL`.

**Why this mode exists:** `nova.chatsconnector.whatsapp-client-api` and `…signal-client-api` run `npm prune --omit=dev` in their Dockerfiles, which removes `ts-node` and with it the seeder — it does not exist in the runtime image, so there is no row to `SELECT`. `sequelize-cli` *is* a runtime dependency, so migrations do run. Insert our own row.

- [ ] **Step 1: Write the failing tests**

```bash
# --- db-insert: no seeder in the image, so write the row ourselves --------------------
# whatsapp and signal prune ts-node out of the runtime image, taking the seeder with it.
# Migrations still run (sequelize-cli is a runtime dependency), so the tables exist and
# are empty. db-token would SELECT nothing and loud-skip forever.
DAST_AUTH_MODE=db-insert DAST_AUTH_HEADER=api_access_token DAST_AUTH_PREFIX="" \
DAST_TOKEN_INSERT_SQL="INSERT INTO tokens (api_token, role_id) VALUES ('%TOKEN%', 1);" \
SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "db-insert mode: write a token, then scan" clean 0

# The token is generated here, never taken from the repository or the image, so there is
# no value to leak and nothing to rotate.
if grep -qE "^exec .*INSERT INTO tokens" "$WORK/dockerlog"; then
    echo "ok   db-insert runs the caller's INSERT"; pass=$((pass + 1))
else
    echo "FAIL db-insert never inserted anything"; fail=$((fail + 1))
fi
if grep -qE "^exec .*%TOKEN%" "$WORK/dockerlog"; then
    echo "FAIL the %TOKEN% placeholder reached the database unsubstituted"; fail=$((fail + 1))
else
    echo "ok   %TOKEN% is substituted before the INSERT runs"; pass=$((pass + 1))
fi

# Same rule as every other mode: the generated value is masked before anything can echo it.
mask_line=$(sed -n 's/^::add-mask:://p' "$WORK/log" | head -1)
if [ -n "$mask_line" ] && grep -qF "$mask_line" "$WORK/dockerlog"; then
    echo "ok   the generated token is masked and is the one injected"; pass=$((pass + 1))
else
    echo "FAIL the generated token was not masked, or not the one used"; fail=$((fail + 1))
fi

# A mode with no INSERT is a broken configuration, not a scan without auth.
DAST_AUTH_MODE=db-insert DAST_TOKEN_INSERT_SQL="" \
    expect "db-insert without token-insert-sql is a scanner error" error 2
```

- [ ] **Step 2: Run to verify they fail**

```bash
./scripts/test-dast-api-scan.sh
```

Expected: the `db-insert` scenario reports `error` (unknown auth-mode) where `clean` was wanted.

- [ ] **Step 3: Implement the mode**

Add a `db-insert)` arm to the `case "${DAST_AUTH_MODE:-login}"` in `dast-api/scan.sh`, after `db-token)`:

```bash
    db-insert)
        # No seeder in the image to produce a token, so produce one. whatsapp and signal
        # run `npm prune --omit=dev`, which removes ts-node and the seeder with it;
        # sequelize-cli survives as a runtime dependency, so the migrations ran and the
        # tables exist and are empty. There is nothing to SELECT and nothing to guess.
        #
        # The value is generated here and lives only in this job's database, which is
        # deleted with the container: nothing to store, nothing to rotate, nothing that
        # could be a real credential by accident.
        [ -n "${DAST_TOKEN_INSERT_SQL:-}" ] || scanner_error "db-insert mode needs a token-insert-sql statement"
        TOKEN="nova-ci-apiscan-$(openssl rand -hex 24)"
        insert_sql="${DAST_TOKEN_INSERT_SQL//%TOKEN%/$TOKEN}"
        docker exec -e PGPASSWORD="${DATABASE_PASSWORD:-password}" nova-pg \
            psql -tAq -h 127.0.0.1 -U "${DATABASE_USERNAME:-postgres}" -d "${DATABASE_NAME:-db_name}" \
            -c "$insert_sql" >/dev/null 2>&1 \
            || not_run "the token INSERT failed — the migration may not have created the table"
        ;;
```

Add to `action.yml`:

```yaml
  token-insert-sql:
    description: "INSERT run against the seeded database when auth-mode is db-insert; %TOKEN% is replaced with a token generated for this run. Required in that mode."
    required: false
    default: ""
```

and `DAST_TOKEN_INSERT_SQL: ${{ inputs.token-insert-sql }}` to the step's `env:`.

The existing empty-token guard (`[ -n "$TOKEN" ] || not_run …`) already covers this mode; the `::add-mask::` line already runs for whatever `TOKEN` holds. Confirm both by reading, and do not duplicate them.

- [ ] **Step 4: Run to verify they pass**

```bash
./scripts/test-dast-api-scan.sh
```

- [ ] **Step 5: Mutation-check the substitution**

```bash
cp .github/actions/dast-api/scan.sh /tmp/m.bak
sed -i '' 's|insert_sql="${DAST_TOKEN_INSERT_SQL//%TOKEN%/$TOKEN}"|insert_sql="$DAST_TOKEN_INSERT_SQL"|' .github/actions/dast-api/scan.sh
./scripts/test-dast-api-scan.sh; cp /tmp/m.bak .github/actions/dast-api/scan.sh
```

Expected: `FAIL the %TOKEN% placeholder reached the database unsubstituted`.

- [ ] **Step 6: Validate, document, commit**

```bash
./scripts/validate.sh
git add -A && git commit -m "Add db-insert auth mode: whatsapp and signal prune their seeder away"
```

---

### Task 5: `env-token` auth mode — for `novatalks.dialer`

**Files:**
- Modify: `.github/actions/dast-api/action.yml`
- Modify: `.github/actions/dast-api/scan.sh`
- Test: `scripts/test-dast-api-scan.sh`

**Interfaces:**
- Produces: a fourth `DAST_AUTH_MODE` value, `env-token`. It generates a token, exports it into the application container through `extra-env`, and injects the same value into ZAP.

**Why:** `novatalks.dialer`'s `src/auth/auth.middleware.ts` accepts any token present in `app.apiAccessTokens`, which `src/config/app.config.ts` builds by splitting the `API_ACCESS_TOKENS` environment variable. No database, no seed, no SQL — and no call out to the engine, because a token that matches the list short-circuits before `fetchTokenInfo`.

**The ordering problem, and its answer:** the token must exist *before* the container starts, because it is passed as an environment variable. Every other mode acquires the token *after* boot. So `env-token` generates its token at the top of the script, alongside `ADMIN_PASS`, and the container-start step appends `-e <VAR>=<token>`.

- [ ] **Step 1: Write the failing tests**

```bash
# --- env-token: the app is handed the token, no database involved ---------------------
# novatalks.dialer's auth middleware accepts any token listed in API_ACCESS_TOKENS and
# short-circuits before it would call the engine. So there is nothing to seed and nothing
# to SELECT — generate a token, hand it to the app, inject the same one into ZAP.
DAST_AUTH_MODE=env-token DAST_TOKEN_ENV_VAR=API_ACCESS_TOKENS \
DAST_AUTH_HEADER=api_access_token DAST_AUTH_PREFIX="" \
SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "env-token mode: generate, export, inject" clean 0

# The same value must reach both sides, or the scan runs unauthenticated and says nothing.
env_token=$(sed -n 's/^::add-mask:://p' "$WORK/log" | grep '^nova-ci-apiscan-' | head -1)
if [ -n "$env_token" ] && grep -qF "API_ACCESS_TOKENS=$env_token" "$WORK/dockerlog"; then
    echo "ok   the app container is given the generated token"; pass=$((pass + 1))
else
    echo "FAIL the app never received the token — every request would be rejected"
    fail=$((fail + 1))
fi
if [ -n "$env_token" ] && grep -E 'zap-api-scan\.py' "$WORK/dockerlog" | grep -qF "$env_token"; then
    echo "ok   ZAP injects the same token the app was given"; pass=$((pass + 1))
else
    echo "FAIL ZAP and the app hold different tokens"; fail=$((fail + 1))
fi

# No variable name is a broken configuration, not a scan without auth.
DAST_AUTH_MODE=env-token DAST_TOKEN_ENV_VAR="" \
    expect "env-token without a variable name is a scanner error" error 2
```

- [ ] **Step 2: Run to verify they fail**

```bash
./scripts/test-dast-api-scan.sh
```

- [ ] **Step 3: Implement the mode**

Near `ADMIN_PASS`, at the top of `dast-api/scan.sh`:

```bash
# env-token acquires its token before the container exists, unlike every other mode,
# because the application reads it from its own environment. Generated and masked here so
# the order stays obvious: no mode may inject a value the runner has not been told to
# redact first.
ENV_TOKEN=""
if [ "${DAST_AUTH_MODE:-login}" = "env-token" ]; then
    [ -n "${DAST_TOKEN_ENV_VAR:-}" ] || scanner_error "env-token mode needs a token-env-var name"
    ENV_TOKEN="nova-ci-apiscan-$(openssl rand -hex 24)"
    echo "::add-mask::${ENV_TOKEN}"
fi
```

`scanner_error` must be defined above this point — check, and move the definition up if it is not.

In the container-start argument assembly, beside `extra_env_args`:

```bash
[ -n "$ENV_TOKEN" ] && app_env_args+=(-e "${DAST_TOKEN_ENV_VAR}=${ENV_TOKEN}")
```

Guard that line against `set -e`: as the last command of a group it would abort on a false test. Write it as `if [ -n "$ENV_TOKEN" ]; then app_env_args+=(…); fi`.

And a fourth `case` arm:

```bash
    env-token)
        # Already generated above — it had to exist before the container did.
        TOKEN="$ENV_TOKEN"
        ;;
```

Add to `action.yml`:

```yaml
  token-env-var:
    description: "Environment variable the application reads its accepted API tokens from, when auth-mode is env-token. Required in that mode. novatalks.dialer uses API_ACCESS_TOKENS."
    required: false
    default: ""
```

and `DAST_TOKEN_ENV_VAR: ${{ inputs.token-env-var }}` in the step's `env:`.

- [ ] **Step 4: Run to verify they pass**

```bash
./scripts/test-dast-api-scan.sh
```

- [ ] **Step 5: Mutation-check that both sides get the same token**

```bash
cp .github/actions/dast-api/scan.sh /tmp/m.bak
sed -i '' 's|        TOKEN="$ENV_TOKEN"|        TOKEN="nova-ci-apiscan-$(openssl rand -hex 24)"|' .github/actions/dast-api/scan.sh
./scripts/test-dast-api-scan.sh; cp /tmp/m.bak .github/actions/dast-api/scan.sh
```

Expected: `FAIL ZAP and the app hold different tokens`. This is the mutation that matters — a scan with a mismatched token is authenticated-looking and completely blind.

- [ ] **Step 6: Validate, document, commit**

```bash
./scripts/validate.sh
git add -A && git commit -m "Add env-token auth mode for novatalks.dialer"
```

---

### Task 6: `ci-dast-pentest.yaml` — ephemeral targets only

Live targets are deliberately **not** in this task. Ephemeral is the safe case; shipping it alone means the dangerous case is reviewed on its own diff.

**Files:**
- Create: `.github/workflows/ci-dast-pentest.yaml`
- Modify: `docs/sast-dast.md`, `docs/reference.md`
- Create: `assets/readme/` entry only if a new docs page is created — it is not; this extends `sast-dast.md`.

**Interfaces:**
- Consumes: `dast_resolve_target` (Task 1); `scan-mode: active` (Task 2); `scan-mode: full` (Task 3).

- [ ] **Step 1: Write the workflow**

```yaml
name: DAST Pentest (active scan)

# The active scanner sends real attack payloads — injection, traversal, command
# execution, and real POST/PUT/DELETE. Three consequences shape this file:
#
#   1. It is manual. An attacking scan should be a decision somebody made, with a
#      timestamp and an actor against it, not something a branch push caused.
#   2. There is no URL input. `repository` is a choice and the target is derived. An
#      attacking scanner that cannot be pointed anywhere cannot be pointed somewhere it
#      must not go — that is stronger than any validation of a free-text field.
#   3. It runs on ubuntu-latest against an image pulled from GHCR, so it costs no
#      self-hosted runner and adds nothing to any build's wall clock.
on:
  workflow_dispatch:
    inputs:
      repository:
        description: "Repository whose latest published image to scan"
        required: true
        type: choice
        options:
          - novatalks.core
          - novatalks.ui
          - nova.botflow
          - nova.chatsconnector.telegram-client-api
          - nova.chatsconnector.whatsapp-client-api
          - nova.chatsconnector.signal-client-api
          - novatalks.dialer
          - novatalks.geoip-api
      surface:
        description: "api = attack the OpenAPI routes; browser = crawl and attack as a browser"
        required: true
        type: choice
        options: [api, browser]
      image_tag:
        description: "GHCR tag to scan; leave blank for the most recent"
        required: false
        type: string

permissions:
  contents: read
  packages: read

jobs:
  pentest:
    name: ZAP active scan
    runs-on: ubuntu-latest
    # An active scan crawls and attacks every route it finds. On novatalks.core's
    # several-hundred-operation API that is tens of minutes, and the default six hours
    # would let a hung scan hold the slot all day.
    timeout-minutes: 120
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Resolve target
        id: target
        env:
          REPO_NAME: ${{ inputs.repository }}
          SURFACE: ${{ inputs.surface }}
        run: |
          set -euo pipefail
          # shellcheck source=.github/actions/dast/targets.sh
          . "${GITHUB_WORKSPACE}/.github/actions/dast/targets.sh"
          # Fails loudly on a repository/surface pair with no arm — a headless connector
          # has no browser surface, and answering for one would scan nothing and report
          # it clean.
          dast_resolve_target "$REPO_NAME" "$SURFACE"
          echo "Resolved $REPO_NAME/$SURFACE: port=$DT_PORT auth=$DT_AUTH_MODE"

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
```

The remaining steps resolve the image tag, then call the composite action. Resolve the tag with the GitHub packages API rather than guessing a name:

```yaml
      - name: Resolve image tag
        id: image
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          REPO_NAME: ${{ inputs.repository }}
          WANTED: ${{ inputs.image_tag }}
        run: |
          set -euo pipefail
          if [ -n "$WANTED" ]; then
            tag="$WANTED"
          else
            # Most recently published tag, taken from the registry rather than
            # reconstructed from a naming convention: the convention has an image suffix
            # and a short SHA in it, and rebuilding that string here would be a fourth
            # place that has to agree with build-image.
            tag=$(gh api "orgs/${GITHUB_REPOSITORY_OWNER}/packages/container/${REPO_NAME}/versions" \
                    --jq '[.[] | select(.metadata.container.tags | length > 0)][0].metadata.container.tags[0]')
          fi
          [ -n "$tag" ] && [ "$tag" != "null" ] \
            || { echo "::error::No published image found for ${REPO_NAME}"; exit 1; }
          echo "ref=ghcr.io/${GITHUB_REPOSITORY_OWNER}/${REPO_NAME}:${tag}" | tee -a "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Add the two scan steps**

One per surface, each `if:`-gated on `inputs.surface`, each calling the composite action already built:

```yaml
      - name: Active API scan
        id: api
        if: ${{ inputs.surface == 'api' }}
        uses: novaitdevteam/nova.ci/.github/actions/dast-api@main
        with:
          image: ${{ steps.image.outputs.ref }}
          scan-mode: active
          report-file: zap-pentest-${{ inputs.repository }}-${{ github.run_id }}.report
          port: ${{ steps.target.outputs.port }}
          health-path: ${{ steps.target.outputs.health_path }}
          spec-path: ${{ steps.target.outputs.spec_path }}
          auth-mode: ${{ steps.target.outputs.auth_mode }}
          login-path: ${{ steps.target.outputs.login_path }}
          auth-header: ${{ steps.target.outputs.auth_header }}
          auth-scheme-prefix: ${{ steps.target.outputs.auth_scheme_prefix }}
          token-sql: ${{ steps.target.outputs.token_sql }}
          token-insert-sql: ${{ steps.target.outputs.token_insert_sql }}
          token-env-var: ${{ steps.target.outputs.token_env_var }}
          setup-command: ${{ steps.target.outputs.setup_command }}
          swagger-enable: ${{ steps.target.outputs.swagger_enable }}
          extra-env: ${{ steps.target.outputs.extra_env }}

      - name: Active browser scan
        id: browser
        if: ${{ inputs.surface == 'browser' }}
        uses: novaitdevteam/nova.ci/.github/actions/dast@main
        with:
          image: ${{ steps.image.outputs.ref }}
          scan-mode: full
          report-file: zap-pentest-${{ inputs.repository }}-${{ github.run_id }}.report
          port: ${{ steps.target.outputs.port }}
          health-path: ${{ steps.target.outputs.health_path }}
          needs-db: ${{ steps.target.outputs.needs_db }}
          needs-nats: ${{ steps.target.outputs.needs_nats }}
          extra-env: ${{ steps.target.outputs.extra_env }}
```

To pass `DT_*` through, the `Resolve target` step must write them to `$GITHUB_OUTPUT` exactly as the build workflow's steps do — heredoc-delimited for `auth_scheme_prefix` (trailing space), `token_sql`, `token_insert_sql` and `extra_env`. Copy that block from `Resolve api-scan target`; do not write a shorter version.

- [ ] **Step 3: Add artifact upload and notification**

Reuse the `ci-dast-live-baseline.yaml` pattern exactly, including the `id: artifact` / `Compose notification` split that puts the report's own download URL in the message:

```yaml
      - name: Upload report artifact
        id: artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: zap-pentest-${{ inputs.repository }}-${{ inputs.surface }}
          path: zap-pentest-*.report
          if-no-files-found: warn

      - name: Compose notification
        id: notice
        if: always()
        env:
          VERDICT: ${{ steps.api.outputs.message || steps.browser.outputs.message }}
          ARTIFACT_URL: ${{ steps.artifact.outputs.artifact-url }}
          REPO_NAME: ${{ inputs.repository }}
          SURFACE: ${{ inputs.surface }}
        run: |
          set -euo pipefail
          run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
          line="${VERDICT:-🗡 DAST pentest (${REPO_NAME}/${SURFACE}): ❌ scan did not complete}"
          {
            echo "message<<PENTEST_EOF"
            printf '%s\n' "🗡 ACTIVE scan · ${REPO_NAME}/${SURFACE} · by ${GITHUB_ACTOR}"
            printf '%s\n' "$line"
            if [ -n "$ARTIFACT_URL" ]; then printf '   📥 Report: %s\n' "$ARTIFACT_URL"; fi
            printf '   📄 Run: %s\n' "$run_url"
            echo "PENTEST_EOF"
          } >> "$GITHUB_OUTPUT"

      - name: Notify
        if: ${{ !cancelled() }}
        uses: novaitdevteam/nova.ci/.github/actions/notify@main
        with:
          message: ${{ steps.notice.outputs.message }}
          telegram_token: ${{ secrets.TG_NOTIFICATION_BOT_TOKEN }}
          telegram_to: ${{ secrets.TG_NOTIFICATION_BOT_ID }}
          gchat_webhook: ${{ secrets.GC_NOTIFICATION_WEBHOOK }}
```

- [ ] **Step 4: Validate**

```bash
./scripts/validate.sh
actionlint .github/workflows/ci-dast-pentest.yaml
```

Expected: `VALIDATION OK`, and **zero** actionlint findings on the new file — it is new, so it inherits none of the pre-existing backlog.

- [ ] **Step 5: Prove it end to end on the one repository already known to boot**

Dispatch against `novatalks.core`, surface `api`. This is the first real active scan and the first proof the workflow works at all.

```bash
gh workflow run ci-dast-pentest.yaml -R novaitdevteam/nova.ci \
  -f repository=novatalks.core -f surface=api
```

Expected: a verdict that is **not** `not run`, with a non-zero operation count. Record the run URL and the counts in the commit message.

- [ ] **Step 6: Document and commit**

Add a "Pentest (active scan)" section to `docs/sast-dast.md` covering: manual only, no URL input, what active means, what it still cannot find. Add the workflow to `docs/reference.md`'s inventory. Add the invariants to `CLAUDE.md` and both `SKILL.md` mirrors.

```bash
git add -A && git commit -m "Add ci-dast-pentest.yaml: the first scan here that actually attacks"
```

---

### Task 7: The live target, behind a typed confirmation

**Files:**
- Modify: `.github/workflows/ci-dast-pentest.yaml`
- Modify: `docs/sast-dast.md`, `CLAUDE.md`, both `SKILL.md`

**This task changes data on a real host.** The allowlisted host is a dedicated security-testing instance, not production, and that assumption is what makes the whole task acceptable. Adding any other host is a separate decision, made by editing the `case` — never at runtime.

- [ ] **Step 1: Add the inputs**

```yaml
      target:
        description: "ephemeral = a container this run starts and kills. live = the allowlisted host — REAL WRITES AND DELETIONS."
        required: true
        default: ephemeral
        type: choice
        options: [ephemeral, live]
      confirm:
        description: "For target=live only: type the host name exactly to confirm you accept data loss"
        required: false
        type: string
```

- [ ] **Step 2: Add the guard, ahead of every other step**

```yaml
      - name: Validate live target
        if: ${{ inputs.target == 'live' }}
        env:
          REPO_NAME: ${{ inputs.repository }}
          CONFIRM: ${{ inputs.confirm }}
        run: |
          set -euo pipefail

          # One host, named here and nowhere else. Same mechanism as
          # ci-dast-live-baseline.yaml's allowlist, and the same reason: a scanner that
          # can be pointed anywhere eventually is.
          case "$REPO_NAME" in
            novatalks.core|novatalks.ui)
              host="novatalks-security.cloud.novatalks.com.ua" ;;
            *)
              echo "::error::'$REPO_NAME' has no allowlisted live host. Live scanning is per-repository and deliberate."
              exit 1 ;;
          esac

          # Typing the host name is the point: it cannot be done by accident, and it
          # cannot be done without reading which host is about to be attacked.
          if [ "$CONFIRM" != "$host" ]; then
            echo "::error::An active scan against ${host} performs real writes and deletions. Re-run with confirm set to exactly: ${host}"
            exit 1
          fi
          echo "host=$host" >> "$GITHUB_OUTPUT"
```

- [ ] **Step 3: Route the scan steps**

When `target == 'live'` neither composite action applies — there is no image to boot, no
database to bring up and no token to seed. Add an inline step, and gate the two existing
scan steps on `inputs.target == 'ephemeral'` so exactly one path ever runs.

The inline step is `ci-dast-live-baseline.yaml`'s, with three changes: `zap-full-scan.py`
instead of `zap-baseline.py`, `-j` when the surface is `browser`, and the full-scan
register. The tally parse still comes from `dast-common.sh` — never re-inlined.

```yaml
      - name: Active scan against the live host
        id: live
        if: ${{ inputs.target == 'live' }}
        env:
          TARGET: https://${{ steps.confirm_live.outputs.host }}
          SURFACE: ${{ inputs.surface }}
          ZAP_IMAGE: "ghcr.io/zaproxy/zaproxy:stable@sha256:781a2bdaea47324e7bab583e2263f21d257b0aee61ed51521a5be45f5f5081ef"
        run: |
          set -euo pipefail
          # shellcheck source=.github/actions/dast/dast-common.sh
          . "${GITHUB_WORKSPACE}/.github/actions/dast/dast-common.sh"

          work_dir="${RUNNER_TEMP:-/tmp}/zap-pentest"
          mkdir -p "$work_dir"
          # World-writable, and it replaces the `--user $(id -u):$(id -g)` the container
          # scans pass: on ubuntu-latest the runner is uid 1001 and zap-full-scan.py
          # writes its Automation Framework plan to Path.home() = /home/zap, which uid
          # 1001 cannot write. Same fix, same reason, as ci-dast-live-baseline.yaml.
          chmod 777 "$work_dir"
          cp "${GITHUB_WORKSPACE}/.github/actions/dast/zap-full-scan.conf" "$work_dir/"

          spider_args=()
          [ "$SURFACE" = browser ] && spider_args=(-j)

          zap_console="${work_dir}/zap-console.log"
          scanner_error() { echo "::error::$1"; exit 1; }

          set +e
          docker run --rm -v "${work_dir}:/zap/wrk:rw" "$ZAP_IMAGE" \
            zap-full-scan.py -t "$TARGET" \
            ${spider_args[@]+"${spider_args[@]}"} \
            -I -c zap-full-scan.conf -w report.md 2>&1 | tee "$zap_console"
          zap_rc=${PIPESTATUS[0]}
          set -e

          case "$zap_rc" in
            0|1|2) : ;;
            *) scanner_error "zap-full-scan.py exited ${zap_rc}" ;;
          esac
          [ -s "${work_dir}/report.md" ] || scanner_error "ZAP produced no report"
          zap_tally_parse "$zap_console" scanner_error
```

Give the Step 2 guard `id: confirm_live` so `steps.confirm_live.outputs.host` resolves.

- [ ] **Step 4: Stamp the result**

Everywhere the outcome appears — the report's first line, the job summary banner, and the notification — prefix:

```
⚠️ LIVE TARGET <host> — this scan performed real writes. Dispatched by <actor>.
```

The banner is not decoration. A report read three months later must not be mistaken for an ephemeral run.

- [ ] **Step 5: Validate and commit**

```bash
./scripts/validate.sh && actionlint .github/workflows/ci-dast-pentest.yaml
git add -A && git commit -m "Allow an active scan against the allowlisted live host, behind a typed confirmation"
```

Do **not** dispatch a live run as part of this task. Ship the mechanism; the first live run is a decision its own owner makes.

---

### Task 8: The four unwired API repositories

**Files:**
- Modify: `.github/actions/dast/targets.sh`
- Modify: `scripts/test-dast-targets.sh`
- Modify: `.github/workflows/ci-build-ntk-on-push-tags-build.yaml` (the `api-scan` job's repository allowlist)

**Read before writing — one repository at a time.** For each, the values come from these files and nowhere else:

| Repository | Read | For |
| --- | --- | --- |
| `…whatsapp-client-api` | `src/shared/guards/roles.guard.ts` | header name |
| | `src/**/token.model.ts`, `token-role.model.ts` | table and column names for the INSERT |
| | `docker/*.Dockerfile` | whether npm and the seeder survive |
| | `.env.example` | which variables the config validator rejects blank |
| `…signal-client-api` | the same four | the same four |
| `novatalks.dialer` | `src/auth/auth.middleware.ts`, `src/config/app.config.ts` | confirms `env-token` and `API_ACCESS_TOKENS` |
| | `docker/*.Dockerfile`, `.env.example` | port, health path, boot dummies |
| `novatalks.geoip-api` | its guard/middleware, Dockerfile, chart | **auth is unknown — it may have none** |

If a repository turns out to have no authentication, its arm sets `DT_AUTH_MODE=none`, the scan runs unauthenticated, and the report says so. That is an honest result. Inventing an auth mode for it is not.

- [ ] **Step 1: Read `…whatsapp-client-api` and write its arm plus its test**

Add to `scripts/test-dast-targets.sh` first, with the values you just read:

```bash
reset_dt; dast_resolve_target nova.chatsconnector.whatsapp-client-api api
check "whatsapp auth mode"  db-insert         "$DT_AUTH_MODE"
check "whatsapp header"     api_access_token  "$DT_AUTH_HEADER"
check "whatsapp prefix"     ""                "$DT_AUTH_SCHEME_PREFIX"
if [ -n "$DT_TOKEN_INSERT_SQL" ]; then
    echo "ok   whatsapp carries an INSERT"; pass=$((pass + 1))
else
    echo "FAIL whatsapp has no INSERT — db-insert would loud-skip"; fail=$((fail + 1))
fi
```

Run it, watch it fail, add the arm, run it again.

- [ ] **Step 2: Repeat for `…signal-client-api`**

Its schema is expected to match whatsapp's, but **verify it rather than copying** — that expectation is exactly the kind that has been wrong twice already.

- [ ] **Step 3: Repeat for `novatalks.dialer`** (`env-token`, `DT_TOKEN_ENV_VAR=API_ACCESS_TOKENS`)

- [ ] **Step 4: Repeat for `novatalks.geoip-api`**

- [ ] **Step 5: Widen the in-build `api-scan` allowlist**

```yaml
      && contains(fromJSON('["novatalks.core","nova.chatsconnector.telegram-client-api","nova.chatsconnector.whatsapp-client-api","nova.chatsconnector.signal-client-api","novatalks.dialer","novatalks.geoip-api"]'), github.event.repository.name)
```

- [ ] **Step 6: Validate and commit**

```bash
./scripts/validate.sh
git add -A && git commit -m "Wire the four remaining API repositories into the DAST target table"
```

---

### Task 9: The browser arms — `novatalks.ui` and `nova.botflow`

**Files:**
- Modify: `.github/actions/dast/targets.sh`, `scripts/test-dast-targets.sh`
- Create: `.github/actions/dast/contexts/novatalks-ui.context`

**This is the task with the real unknown.** A ZAP context file is XML describing the login form: its URL, the field names, the credentials, and a regex that tells ZAP whether it is still logged in. The selectors have to be read out of the running application, and nothing in this plan can predict them.

- [ ] **Step 1: Boot the UI image locally and read the login form**

```bash
docker run -d --name ui-probe -p 8000:8000 ghcr.io/novaitdevteam/novatalks.ui:<tag>
curl -s http://127.0.0.1:8000/ | head -50
```

Record: the login POST URL, the username and password field names, and a string present only when authenticated (for `loggedInIndicatorRegex`).

- [ ] **Step 2: Write the context file** with those values, and a `loggedOutIndicatorRegex` too — a context with only one of the two lets ZAP silently scan as an anonymous user, which is the "authenticated-looking, completely blind" failure again.

- [ ] **Step 3: Pass the context to `zap-full-scan.py`**

In `dast/scan.sh`, inside the `full)` arm:

```bash
        # A context file teaches ZAP the login form. Without one the "authenticated"
        # scan is an anonymous crawl that looks exactly like a successful one — the same
        # failure shape as the unquoted -z replacer in dast-api. -U names the user
        # defined inside the context; both flags travel together or neither does.
        if [ -n "${DAST_ZAP_CONTEXT:-}" ]; then
            cp "${DAST_ACTION_ROOT}/contexts/${DAST_ZAP_CONTEXT}" "${RUNNER_TEMP:-/tmp}/"
            zap_mode_args+=(-n "$DAST_ZAP_CONTEXT" -U nova-ci-dast)
        fi
```

And the scenario, in `scripts/test-dast-scan.sh`:

```bash
DAST_SCAN_MODE=full DAST_ZAP_CONTEXT=novatalks-ui.context \
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "full mode with a context reports a clean scan" clean 0
if grep -E 'zap-full-scan\.py' "$WORK/dockerlog" | grep -q -- "-n novatalks-ui.context"; then
    echo "ok   the context file is passed"; pass=$((pass + 1))
else
    echo "FAIL no -n — the scan would run anonymously and look successful"; fail=$((fail + 1))
fi
if grep -E 'zap-full-scan\.py' "$WORK/dockerlog" | grep -q -- "-U nova-ci-dast"; then
    echo "ok   the context user is selected"; pass=$((pass + 1))
else
    echo "FAIL -n without -U — ZAP loads the context and scans as nobody"; fail=$((fail + 1))
fi

unset DAST_ZAP_CONTEXT
DAST_SCAN_MODE=full SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "full mode without a context still scans" clean 0
if grep -E 'zap-full-scan\.py' "$WORK/dockerlog" | grep -q -- "-U"; then
    echo "FAIL -U passed with no context to define the user"; fail=$((fail + 1))
else
    echo "ok   no context means no -n and no -U"; pass=$((pass + 1))
fi
```

Add `DAST_ZAP_CONTEXT: ${{ inputs.zap-context }}` to `dast/action.yml`'s step `env:` and a
matching `zap-context` input, defaulting to `""`.

- [ ] **Step 4: Add the `nova.botflow` browser arm** — it already has one for the baseline; confirm the same port and health path serve the full scan.

- [ ] **Step 5: Prove it**

```bash
gh workflow run ci-dast-pentest.yaml -R novaitdevteam/nova.ci \
  -f repository=novatalks.ui -f surface=browser
```

Expected: a URL count **substantially higher** than the baseline's on the same host. If it is the same, `-j` or the context is not working and the scan is still seeing one page — that is a failure, not a clean result.

- [ ] **Step 6: Validate and commit**

---

### Task 10: Live proof for all eight, and the exit criterion

Not a coding task. The plan is not done when the code is written; it is done when every repository has produced a real verdict.

- [ ] **Step 1: Run each repository's scan and record the result**

For each of the eight, on the surfaces it has, dispatch `ci-dast-pentest.yaml` with `target=ephemeral` and record: run URL, verdict, operation or URL count, and duration.

- [ ] **Step 2: Fix every `not run`**

A `not run` is now always accompanied by the container's log and the failing command's output (PR #36). Diagnose from that, fix the arm or the mode, re-run. **A repository is not done until it produces a non-`not-run` verdict with a non-zero count.**

- [ ] **Step 3: Write the results table into `docs/sast-dast.md`**

Repository, surface, verdict, count, run URL, date. This is the evidence the quarterly report is assembled from, and it is also the thing that makes a future regression visible.

- [ ] **Step 4: Record what is still not covered**

In the same section, plainly: no IDOR, no privilege escalation, no business-logic flaws, no chained exploits. An active scanner has no model of intent. Nobody should read this table as a penetration test.

- [ ] **Step 5: Commit**

```bash
git add docs/sast-dast.md && git commit -m "Record the live DAST proof for all eight repositories"
```
