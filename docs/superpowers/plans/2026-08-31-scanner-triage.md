# Scanner Triage and Real-Picture Reporting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make both scanners report everything they found, and give ZAP a written register that says which findings must be fixed and which are accepted.

**Architecture:** Semgrep stops filtering to a single severity and reports `ERROR` and `WARNING` as two counts. ZAP gains `-c`, a tab-separated triage config shipped with the action, and its counts come from the one tally line `zap-baseline.py` prints at the end of every completed scan instead of from a single grepped severity. The DAST exit-code ladder is corrected to the verified upstream table so that a `FAIL`-level finding reports as a finding rather than reddening the build.

**Tech Stack:** Bash, `jq`, `awk`, GitHub Actions composite actions, Semgrep OSS, OWASP ZAP baseline.

**Spec:** [`docs/superpowers/specs/2026-08-31-scanner-triage.md`](../specs/2026-08-31-scanner-triage.md)

## Global Constraints

- `warn-only` governs **findings**. A scanner that could not run reds the job. Never collapse the two. No change in this plan may make a build red for a finding.
- A DAST application that fails to boot stays a **loud skip**: green build, explicit `⚠️ not run — <reason>`.
- Scanner images stay pinned by tag **and** digest. Do not touch `SEMGREP_IMAGE` or `ZAP_IMAGE`.
- Keep the `tee` capture and `${PIPESTATUS[0]}` in `.github/actions/dast/scan.sh` exactly as they are, comments included.
- Do not remove the Semgrep canary guard or the `.errors[]` check beside it.
- Changing either `scan.sh` means adding scenarios to `scripts/test-sast-scan.sh` or `scripts/test-dast-scan.sh` **in the same commit**.
- No workflow may invoke Semgrep or ZAP directly; `validate.sh` fails on it.
- Run `./scripts/validate.sh` after every task. Baseline before this plan: SAST **19** checks, DAST **91** checks, create-runner **22**, secret-scan **24**, ending `VALIDATION OK`.
- File paths in documentation are relative to the repository root (`../` from inside `docs/`).
- Every commit ends with the trailer `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.

---

### Task 1: Semgrep reports `ERROR` and `WARNING` as two counts

**Files:**
- Modify: `.github/actions/semgrep/action.yml`
- Modify: `.github/actions/semgrep/scan.sh`
- Test: `scripts/test-sast-scan.sh`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: the composite action gains an output `warnings` (string, integer). Output `findings` keeps its name and becomes the `ERROR` count specifically. Input `severity` is **removed**. `scan.sh` no longer reads `SEMGREP_SEVERITY`.

- [ ] **Step 1: Update the two harness scenarios that assert the old behaviour**

Two existing scenarios encode the behaviour this task deletes and will fail otherwise. In `scripts/test-sast-scan.sh`, replace lines 110–111:

```bash
SHIM_JSON="$(semgrep_json yes WARNING)" SHIM_RC=1 \
    expect "WARNING is not counted at ERROR severity" clean 0
```

with:

```bash
# WARNING used to be invisible: the old filter was an exact equality on ERROR, and the
# same filter built the report body, so a repository's WARNING findings appeared in
# neither the count nor the published artifact. novatalks.core had 12 nobody ever saw.
SHIM_JSON="$(semgrep_json yes WARNING)" SHIM_RC=1 \
    expect "a lone WARNING is a finding, not a clean scan" findings 0
assert_warnings "the WARNING lands in its own count" 1
assert_report "report lists the WARNING section" "=== WARNING: 1 ==="
```

and replace lines 170–175 (the `SEMGREP_SEVERITY=INFO` scenario, whose input no longer exists):

```bash
# The canary is mounted from the action's own directory and carries a hardcoded INFO
# severity. It proves the engine ran and must never be countable as a finding of the
# repository under scan, nor leak into the published report.
SHIM_JSON="$(semgrep_json yes)" SHIM_RC=0 \
    expect "canary alone is a clean scan" clean 0
assert_warnings "canary alone counts no warnings" 0
assert_report "report never contains the canary" "nova-ci-semgrep-canary" --absent
```

- [ ] **Step 2: Add the `assert_warnings` helper and the new scenarios**

In `scripts/test-sast-scan.sh`, after `assert_report()` (currently ends line 100), add:

```bash
assert_warnings() { # assert_warnings <name> <expected>
    local got
    got=$(sed -n 's/^warnings=//p' "$WORK/output")
    if [ "$got" = "$2" ]; then
        echo "ok   $1"; pass=$((pass + 1))
    else
        echo "FAIL $1 — expected warnings=$2, got warnings=$got"; fail=$((fail + 1))
    fi
}
```

Then, immediately before the final `echo "--- $pass passed, $fail failed"` line, add:

```bash
# The real picture: both levels counted, both listed, neither hiding the other.
SHIM_JSON="$(semgrep_json yes ERROR ERROR WARNING WARNING WARNING)" SHIM_RC=1 \
    expect "ERROR and WARNING are counted separately" findings 2
assert_warnings "the three WARNING findings are their own number" 3
assert_report "report lists the ERROR section" "=== ERROR: 2 ==="
assert_report "report lists the WARNING section too" "=== WARNING: 3 ==="

# INFO is counted for the summary but deliberately kept out of the report body: the OSS
# packs emit it liberally and it would bury the two levels that carry a decision.
SHIM_JSON="$(semgrep_json yes INFO INFO)" SHIM_RC=1 \
    expect "INFO alone is not a finding" clean 0
assert_warnings "INFO alone counts no warnings" 0
if grep -q 'INFO: 2' "$WORK/summary"; then
    echo "ok   INFO findings are still counted in the job summary"; pass=$((pass + 1))
else
    echo "FAIL the job summary does not report the INFO count"; fail=$((fail + 1))
fi
```

- [ ] **Step 3: Remove `SEMGREP_SEVERITY` from the harness environment**

In `scripts/test-sast-scan.sh`, delete line 64 from the `expect()` environment block:

```bash
    SEMGREP_SEVERITY="${SEMGREP_SEVERITY:-ERROR}" \
```

- [ ] **Step 4: Run the harness to verify it fails**

Run: `./scripts/test-sast-scan.sh`
Expected: FAIL. `scan.sh` still requires `SEMGREP_SEVERITY` via `: "${SEMGREP_SEVERITY:?}"`, so every scenario aborts with an unbound-variable error before producing any outcome.

- [ ] **Step 5: Rewrite the counting and reporting in `scan.sh`**

In `.github/actions/semgrep/scan.sh`, change the requirement line (currently line 13) from:

```bash
: "${SEMGREP_IMAGE:?}" "${SEMGREP_CONFIGS:?}" "${SEMGREP_SEVERITY:?}"
```

to:

```bash
: "${SEMGREP_IMAGE:?}" "${SEMGREP_CONFIGS:?}"
```

Then replace the whole block from the `canary_hits=` guard's closing `[ "$canary_hits" -gt 0 ] || finish_error ...` line down to and including the `} > "$SEMGREP_REPORT_FILE"` closing brace with:

```bash
[ "$canary_hits" -gt 0 ] || finish_error "the canary rule did not fire — the rule engine did not run"

# The canary is mounted from this action's own directory, not from the repository under
# scan, so it must be excluded from every bucket. It is excluded by check_id rather than
# by severity: severity used to be a caller input and the exclusion silently stopped
# working whenever the two happened to coincide.
count_at() { # count_at <severity>
    jq --arg sev "$1" \
        '[.results[] | select(.extra.severity == $sev
            and (.check_id | test("nova-ci-semgrep-canary") | not))] | length' "$json"
}

list_at() { # list_at <severity>
    jq -r --arg sev "$1" \
        '.results[] | select(.extra.severity == $sev
            and (.check_id | test("nova-ci-semgrep-canary") | not))
         | "\(.path):\(.start.line)  [\(.check_id)]\n    \(.extra.message)\n"' "$json"
}

errors=$(count_at ERROR)
warnings=$(count_at WARNING)
infos=$(count_at INFO)

# Both decision-carrying levels are listed. INFO is counted for the summary only: the
# registry packs emit it liberally, and burying ERROR and WARNING under it is how a
# report stops being read.
{
    echo "=============================="
    echo " SAST: Semgrep"
    echo " Image:    ${SEMGREP_IMAGE}"
    echo " Configs:  ${SEMGREP_CONFIGS}"
    echo "=============================="
    echo ""
    echo "=== ERROR: ${errors} ==="
    echo ""
    list_at ERROR
    echo "=== WARNING: ${warnings} ==="
    echo ""
    list_at WARNING
    echo "=== INFO: ${infos} (counted, not listed) ==="
} > "$SEMGREP_REPORT_FILE"
```

- [ ] **Step 6: Rewrite the outcome, message and summary in `scan.sh`**

Replace the block from `if [ "$findings" -gt 0 ]; then` down to the final
`echo "Semgrep results — ..."` line with:

```bash
if [ "$errors" -gt 0 ] || [ "$warnings" -gt 0 ]; then
    outcome=findings
    echo "::warning::Semgrep found ${errors} ERROR and ${warnings} WARNING finding(s). See ${SEMGREP_REPORT_FILE}."
    message="🔍 SAST (Semgrep): 🟡 ${errors} error · ${warnings} warning"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    alert=WARNING
    headline="⚠️ ${errors} ERROR and ${warnings} WARNING finding(s) — review the report."
else
    outcome=clean
    message="🔍 SAST (Semgrep): 🟢 clean"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    alert=NOTE
    headline="✅ No ERROR or WARNING findings."
fi

{
    echo "## 🔍 SAST (Semgrep)"
    echo ""
    echo "> [!${alert}]"
    echo "> ${headline}"
    echo ""
    echo "- Image: \`${SEMGREP_IMAGE}\`"
    echo "- Configs: \`${SEMGREP_CONFIGS}\`"
    echo "- Files scanned: ${scanned}"
    echo "- ERROR: ${errors} · WARNING: ${warnings} · INFO: ${infos}"
    echo "- Report: ${REPORT_URL:-not published}"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

emit outcome "$outcome"
emit findings "$errors"
emit warnings "$warnings"
emit_message "$message"
echo "Semgrep results — ERROR: ${errors}, WARNING: ${warnings}, INFO: ${infos} (outcome: ${outcome})"
```

- [ ] **Step 7: Add `emit warnings 0` to the error path**

In `finish_error()`, immediately after the existing `emit findings 0` line, add:

```bash
    emit warnings 0
```

- [ ] **Step 8: Update `action.yml`**

In `.github/actions/semgrep/action.yml`, delete the whole `severity:` input block:

```yaml
  severity:
    description: "Severity counted as a finding"
    required: false
    default: "ERROR"
```

Add a `warnings` output after the `findings` output:

```yaml
  warnings:
    description: "Number of WARNING findings — reported alongside ERROR, never hidden behind it"
    value: ${{ steps.scan.outputs.warnings }}
```

Change the `findings` output description to:

```yaml
  findings:
    description: "Number of ERROR findings"
    value: ${{ steps.scan.outputs.findings }}
```

And delete the `SEMGREP_SEVERITY` line from the step's `env:` block:

```yaml
        SEMGREP_SEVERITY: ${{ inputs.severity }}
```

- [ ] **Step 9: Run the harness to verify it passes**

Run: `./scripts/test-sast-scan.sh`
Expected: PASS, `--- 27 passed, 0 failed`.

- [ ] **Step 10: Prove the new counting is not vacuous**

Temporarily change `warnings=$(count_at WARNING)` to `warnings=0` in `scan.sh`, run `./scripts/test-sast-scan.sh`, and confirm at least three checks fail (`the WARNING lands in its own count`, `the three WARNING findings are their own number`, `a lone WARNING is a finding, not a clean scan`). Restore the line and confirm the harness is green again.

- [ ] **Step 11: Run the full validator**

Run: `./scripts/validate.sh`
Expected: `VALIDATION OK`.

- [ ] **Step 12: Commit**

```bash
git add .github/actions/semgrep/action.yml .github/actions/semgrep/scan.sh scripts/test-sast-scan.sh
git commit -m "$(cat <<'EOF'
Report Semgrep WARNING findings instead of hiding them behind ERROR

The severity filter was an exact equality on ERROR, and the same filter
built the report body — so WARNING and INFO findings appeared in neither
the count nor the .report published as a release asset. novatalks.core
produced 12 WARNING findings that have never been visible to anyone,
including the quarterly evidence pack the scan exists to feed.

ERROR and WARNING are now counted and listed separately; INFO is counted
for the job summary but stays out of the report body, where the registry
packs' volume would bury the two levels that carry a decision.

The `severity` input is removed rather than repurposed: no caller set it,
and with both levels reported there is nothing left for it to select.
That also retires the hazard it carried — the canary was excluded from
the count by check_id precisely because a caller could set severity to
the canary's own INFO.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Ship the ZAP triage register and validate it before use

**Files:**
- Create: `.github/actions/dast/zap-baseline.conf`
- Modify: `.github/actions/dast/scan.sh`
- Test: `scripts/test-dast-scan.sh`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `scan.sh` now requires the environment variable `DAST_ACTION_ROOT` (already set by `action.yml`; the harness must set it too) and defines the shell variable `zap_conf`, the path of the validated config copy inside `RUNNER_TEMP`, consumed by Task 3's `docker run`.

- [ ] **Step 1: Create the triage register**

Create `.github/actions/dast/zap-baseline.conf` with exactly this content. It has no rule entries on purpose — which ZAP rules are acceptable is a risk-acceptance decision, and an entry-free config leaves every rule at its `WARN` default, so behaviour on day one is identical to today's.

```
# nova.ci — OWASP ZAP baseline triage register
#
# This file decides what a DAST finding MEANS. Every rule ZAP loads defaults to WARN;
# an entry here overrides that for one rule ID.
#
#   FAIL    must be fixed — counted and reported separately from warnings
#   WARN    the default — no entry needed
#   INFO    noted, not a warning — out of the warning count, still in the report
#   IGNORE  accepted risk — the reason column is not optional
#   PASS    treated as passing
#
# TAB-separated, three fields minimum:
#
#   <rule_id>	<LEVEL>	<why this decision was made, and who accepted it>
#
# A rule can also be scoped out for particular URLs only:
#
#   <id>,<id>	OUTOFSCOPE	<regex matched against the alert URL>
#
# Worked example — illustrative only, do not uncomment:
#
#   10038	IGNORE	CSP is terminated at the ingress, not in the app — NC2-XXXX, IS manager
#
# Rule IDs are NOT written from memory. Generate the list the pinned image actually
# loads, then copy the ones you need:
#
#   docker run --rm -v "$PWD:/zap/wrk:rw" ghcr.io/zaproxy/zaproxy:stable \
#       zap-baseline.py -t http://example.com -g zap-rules.conf
#
# Known limit: a well-formed line naming a rule ID that does not exist is silently
# inert. ZAP reports alert counts per bucket, never which configured IDs matched, so an
# IGNORE that applied and an IGNORE that was mistyped are indistinguishable. scan.sh
# validates the shape of every line; it cannot validate the IDs.
#
# No entries yet: the mechanism, not the policy. Adding a line is a decision to accept,
# escalate or downgrade a class of finding, and belongs to whoever signs the quarterly
# report.
```

- [ ] **Step 2: Write the failing harness scenarios**

In `scripts/test-dast-scan.sh`, immediately before the final `echo "--- $pass passed, $fail failed"` line, add:

```bash
# --- the ZAP triage register -------------------------------------------------------
# The config is what says "this finding is accepted" and "this one must be fixed". It
# reaches ZAP through /zap/wrk, which is the bind mount of RUNNER_TEMP, because
# zap-baseline.py resolves -c relative to that directory and nothing else.
CONF_DIR="$WORK/action-root"
mkdir -p "$CONF_DIR"

conf_scenario() { # conf_scenario <content>
    printf '%s\n' "$1" > "$CONF_DIR/zap-baseline.conf"
}

conf_scenario '# a comment

10038	IGNORE	terminated at the ingress
10020,10021	OUTOFSCOPE	^http://127\.0\.0\.1:3000/healthz'
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 0	WARN-INPROG: 0	INFO: 0	IGNORE: 1	PASS: 40" \
DAST_ACTION_ROOT="$CONF_DIR" \
    expect "a well-formed triage config is accepted" clean 0
if grep -qE '^run .*zaproxy.* -c zap-baseline\.conf' "$WORK/dockerlog"; then
    echo "ok   the triage config is passed to zap-baseline.py"; pass=$((pass + 1))
else
    echo "FAIL zap-baseline.py was invoked without -c"
    grep -E '^run .*zaproxy' "$WORK/dockerlog" | sed 's/^/     /'
    fail=$((fail + 1))
fi
if [ -f "$WORK/zap-baseline.conf" ]; then
    echo "ok   the triage config is copied into RUNNER_TEMP, which /zap/wrk mounts"; pass=$((pass + 1))
else
    echo "FAIL the triage config never reached RUNNER_TEMP"; fail=$((fail + 1))
fi

# A malformed register is a broken gate, not a warning: an IGNORE that fails to parse
# means ZAP silently applies a policy nobody wrote. ZAP exits 3 on it, but its reason
# lands in a log nobody reads, and a check of our own is one this harness can cover.
conf_scenario '10038	IGNORE'
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 DAST_ACTION_ROOT="$CONF_DIR" \
    expect "a line with too few fields is a scanner error" error 2

conf_scenario '10038	MAYBE	not a level'
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 DAST_ACTION_ROOT="$CONF_DIR" \
    expect "an unknown level is a scanner error" error 2

conf_scenario '# only comments, no entries — every rule keeps its WARN default'
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 0	WARN-INPROG: 0	INFO: 0	IGNORE: 0	PASS: 40" \
DAST_ACTION_ROOT="$CONF_DIR" \
    expect "an entry-free register is valid, not an error" clean 0

rm -f "$CONF_DIR/zap-baseline.conf"
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 DAST_ACTION_ROOT="$CONF_DIR" \
    expect "a missing triage register is a scanner error, never a clean scan" error 2

# The register that actually ships must itself be valid — a broken one would red every
# DAST job on trunk, and nothing else in the harness reads the real file.
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 0	WARN-INPROG: 0	INFO: 0	IGNORE: 0	PASS: 40" \
DAST_ACTION_ROOT="$ROOT/.github/actions/dast" \
    expect "the register committed to this repository parses" clean 0
```

- [ ] **Step 3: Set `DAST_ACTION_ROOT` in the harness environment**

The harness never set it, so without this every scenario aborts. In `scripts/test-dast-scan.sh`, inside the `expect()` environment block, add this line immediately after the `ZAP_IMAGE=...` line:

```bash
    DAST_ACTION_ROOT="${DAST_ACTION_ROOT:-$ROOT/.github/actions/dast}" \
```

- [ ] **Step 4: Teach the docker shim to record the ZAP argument line**

The shim already logs every invocation to `$SHIM_LOG` via `echo "$*"`, so `-c zap-baseline.conf` will appear without any shim change. Verify by reading the first line of `$WORK/bin/docker` in `scripts/test-dast-scan.sh` — it must still be `echo "$*" >> "${SHIM_LOG:?}"`. No edit is expected here; this step is a check, not a change.

- [ ] **Step 5: Run the harness to verify it fails**

Run: `./scripts/test-dast-scan.sh`
Expected: FAIL. The new scenarios fail because `scan.sh` neither reads a config nor passes `-c`; the "well-formed config" scenario reports `clean` but the `-c` and RUNNER_TEMP-copy checks fail, and the three malformed/missing scenarios report `clean 0` instead of `error 2`.

- [ ] **Step 6: Add the requirement and paths to `scan.sh`**

In `.github/actions/dast/scan.sh`, change the requirement line (currently line 24) from:

```bash
: "${ZAP_IMAGE:?}" "${DAST_REPORT_FILE:?}"
```

to:

```bash
: "${ZAP_IMAGE:?}" "${DAST_REPORT_FILE:?}" "${DAST_ACTION_ROOT:?}"
```

Then, immediately after the existing `zap_console=` declaration and its comment, add:

```bash
# The triage register: which findings must be fixed, which are accepted, and why. Copied
# into RUNNER_TEMP because zap-baseline.py resolves -c against /zap/wrk/ and nowhere
# else, and /zap/wrk is the bind mount of that directory.
zap_conf_src="${DAST_ACTION_ROOT}/zap-baseline.conf"
zap_conf="${RUNNER_TEMP:-/tmp}/zap-baseline.conf"
```

- [ ] **Step 7: Add the validation, after the `trap` and before any container starts**

In `.github/actions/dast/scan.sh`, immediately after the `scanner_error()` function definition closes and before the `if [ "$DAST_NEEDS_DB" = "true" ]; then` line, add:

```bash
# Validated before anything is booted: a broken register means ZAP silently applies a
# policy nobody wrote, and finding that out after a five-minute stack boot helps nobody.
# ZAP's own handling is loud enough (sys.exit(3) on a malformed line, an uncaught
# FileNotFoundError on a missing one) but its reason lands in a log nobody reads, and a
# check of our own is one the harness can cover.
[ -r "$zap_conf_src" ] || scanner_error "the ZAP triage register is missing or unreadable: ${zap_conf_src}"

# Grammar per zap_common.py:148-176 — at least two tabs, and a level from the fixed set
# at zap_common.py:57 plus OUTOFSCOPE, which load_config checks before the level list.
# What this cannot catch is a well-formed line naming a rule ID that does not exist: ZAP
# reports alert counts per bucket, never which configured IDs matched, so an IGNORE that
# applied and an IGNORE that was mistyped are indistinguishable from the outside.
conf_bad="$(awk -F'\t' '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    NF < 3 { printf "line %d: fewer than three tab-separated fields; ", NR; next }
    $2 != "PASS" && $2 != "IGNORE" && $2 != "INFO" && $2 != "WARN" && $2 != "FAIL" && $2 != "OUTOFSCOPE" {
        printf "line %d: unknown level \"%s\"; ", NR, $2 }
' "$zap_conf_src")"
[ -z "$conf_bad" ] || scanner_error "the ZAP triage register is malformed — ${conf_bad}"
cp "$zap_conf_src" "$zap_conf"
```

- [ ] **Step 8: Pass `-c` to `zap-baseline.py`**

In `.github/actions/dast/scan.sh`, change the ZAP invocation from:

```bash
    "$ZAP_IMAGE" zap-baseline.py -t "$target" \
    -I -w "$(basename "$zap_out")" 2>&1 | tee "$zap_console"
```

to:

```bash
    "$ZAP_IMAGE" zap-baseline.py -t "$target" \
    -I -c "$(basename "$zap_conf")" -w "$(basename "$zap_out")" 2>&1 | tee "$zap_console"
```

- [ ] **Step 9: Run the harness to verify it passes**

Run: `./scripts/test-dast-scan.sh`
Expected: PASS, `--- 102 passed, 0 failed`.

- [ ] **Step 10: Prove the validation is not vacuous**

Temporarily delete the `[ -z "$conf_bad" ] || scanner_error ...` line, run `./scripts/test-dast-scan.sh`, and confirm exactly the two malformed-config scenarios fail. Restore the line and confirm green.

- [ ] **Step 11: Run the full validator**

Run: `./scripts/validate.sh`
Expected: `VALIDATION OK`.

- [ ] **Step 12: Commit**

```bash
git add .github/actions/dast/zap-baseline.conf .github/actions/dast/scan.sh scripts/test-dast-scan.sh
git commit -m "$(cat <<'EOF'
Give ZAP a triage register for must-fix versus accepted findings

Every ZAP alert was a WARN with no way to record a decision about it. The
count could only go up, so the first thirty-item run would also be the
run where people stopped reading it.

zap-baseline.py's own -c config is that register: tab-separated, one line
per rule ID, a level from PASS/IGNORE/INFO/WARN/FAIL, and a third column
for the reason. It ships with no entries — an entry-free config leaves
every rule at its WARN default, so behaviour is unchanged today. Which
rules are acceptable is a risk-acceptance decision, not a CI one.

scan.sh validates the shape of every line before booting anything and
treats a malformed or missing register as a broken gate. It cannot
validate rule IDs: ZAP reports counts per bucket, never which configured
IDs matched, so a mistyped IGNORE is silently inert. Said so in the file
rather than implying a guarantee that does not exist.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Count every ZAP severity from the tally line, and fix the exit ladder

**Files:**
- Modify: `.github/actions/dast/scan.sh`
- Modify: `.github/actions/dast/action.yml`
- Test: `scripts/test-dast-scan.sh`

**Interfaces:**
- Consumes: the shell variable `zap_conf` from Task 2.
- Produces: the composite action gains an output `failures` (string, integer — the `FAIL-NEW` count). Output `findings` keeps meaning `WARN-NEW`. `outcome` gains no new value; it is `findings` when either count is non-zero.

- [ ] **Step 1: Write the failing harness scenarios**

In `scripts/test-dast-scan.sh`, immediately before the final `echo "--- $pass passed, $fail failed"` line, add:

```bash
# --- the tally line and the exit ladder --------------------------------------------
assert_failures() { # assert_failures <name> <expected>
    local got
    got=$(sed -n 's/^failures=//p' "$WORK/output")
    if [ "$got" = "$2" ]; then
        echo "ok   $1"; pass=$((pass + 1))
    else
        echo "FAIL $1 — expected failures=$2, got failures=$got"; fail=$((fail + 1))
    fi
}

# zap-baseline.py exits 1 when FAIL-level findings are present (zap-baseline.py:701) and
# -I does not suppress it — -I gates exit 2 alone. Treating 1 as a broken scanner would
# red a build for a finding the moment the register gets its first FAIL entry, which is
# exactly the collapse `warn-only governs findings` exists to prevent.
SHIM_CURL_RC=0 SHIM_ZAP_RC=1 SHIM_ZAP_CONSOLE="FAIL-NEW: 2	FAIL-INPROG: 0	WARN-NEW: 5	WARN-INPROG: 0	INFO: 1	IGNORE: 3	PASS: 30" \
    expect "a FAIL-level finding is a finding, not a broken scanner" findings 0
assert_failures "FAIL-NEW is counted on its own" 2
assert_findings "WARN-NEW keeps its own count alongside it" 5
if grep -q 'must-fix' "$WORK/output"; then
    echo "ok   the notification distinguishes must-fix from warnings"; pass=$((pass + 1))
else
    echo "FAIL the notification does not mention must-fix"; fail=$((fail + 1))
fi

# All six numbers come from one line, so a clean run can still say what was suppressed.
# A register nobody can see is a register nobody audits.
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 0	WARN-INPROG: 0	INFO: 4	IGNORE: 7	PASS: 30" \
    expect "a clean run still reports info and accepted counts" clean 0
assert_failures "a clean run reports zero failures" 0
if grep -q '4 info' "$WORK/output" && grep -q '7 accepted' "$WORK/output"; then
    echo "ok   the clean notification names what was suppressed"; pass=$((pass + 1))
else
    echo "FAIL the clean notification hides the info and accepted counts"
    sed 's/^/     /' "$WORK/output"
    fail=$((fail + 1))
fi
if grep -q 'accepted (IGNORE): 7' "$WORK/report"; then
    echo "ok   the report breaks the run down by level"; pass=$((pass + 1))
else
    echo "FAIL the report has no per-level breakdown"; fail=$((fail + 1))
fi

# A completed scan always prints the tally (zap-baseline.py:666, unconditional). Its
# absence means the scan did not finish, and an unfinished scan reporting zero findings
# is the exact failure this whole job exists to avoid — the same shape as the Semgrep
# canary and the `git rev-list --count` guard on the secret scan.
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: everything looked fine" \
    expect "a console with no tally line is a scanner error, never clean" error 2

SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="FAIL-NEW: none	FAIL-INPROG: 0	WARN-NEW: 5	WARN-INPROG: 0	INFO: 1	IGNORE: 3	PASS: 30" \
    expect "a non-numeric tally is a scanner error" error 2

# Exit 3 is both "an exception was raised" and "nothing passed, warned or failed" — no
# rule ran at all. Both are broken gates.
SHIM_CURL_RC=0 SHIM_ZAP_RC=3 \
    expect "exit 3 stays a scanner error" error 2
```

- [ ] **Step 2: Run the harness to verify it fails**

Run: `./scripts/test-dast-scan.sh`
Expected: FAIL. `exit 1` currently hits the `*)` arm and reports `error 2` instead of `findings 0`; `failures` is never emitted; the tally-absent and non-numeric scenarios report `clean 0`.

- [ ] **Step 3: Replace the exit-code `case` in `scan.sh`**

In `.github/actions/dast/scan.sh`, replace:

```bash
# zap-baseline.py: 0 = nothing, 2 = warnings present (with -I it never returns 1),
# anything else means ZAP could not do its job.
case "$zap_rc" in
    0|2) : ;;
    *)   scanner_error "zap-baseline.py exited ${zap_rc}" ;;
esac
```

with:

```bash
# The ladder, verified against zap-baseline.py:697-708 rather than assumed:
#   0  passes only
#   1  FAIL-level findings present — a finding, not a broken scanner. -I does NOT
#      suppress this; it gates exit 2 alone (`elif (not ignore_warn) and warn_count`).
#      An earlier comment here claimed -I made 1 unreachable, which was simply wrong,
#      and would have reddened a trunk build for a finding the first time the triage
#      register gained a FAIL entry.
#   2  warnings with -I absent — unreachable while we pass -I, kept so that removing -I
#      never silently turns a findings run into a broken-gate report.
#   3  an exception, or nothing passed, warned or failed at all. Both are broken gates.
case "$zap_rc" in
    0|1|2) : ;;
    *)     scanner_error "zap-baseline.py exited ${zap_rc}" ;;
esac
```

- [ ] **Step 4: Replace the finding count with the tally parse**

In `.github/actions/dast/scan.sh`, replace:

```bash
# Counted from stdout, not from the -w report: that report is the traditional
# "ZAP Scanning Report" markdown (## Summary of Alerts + per-risk sections) and contains
# no WARN-NEW at all, so counting it there is a permanent zero — every run green,
# including one with twenty warnings. `^WARN-NEW: ` matches the per-rule lines only; the
# trailing tally line starts with FAIL-NEW:.
findings=$(grep -cE '^WARN-NEW: ' "$zap_console" || true)
findings="${findings:-0}"
```

with:

```bash
# Counted from stdout, not from the -w report: that report is the traditional
# "ZAP Scanning Report" markdown (## Summary of Alerts + per-risk sections) and contains
# no WARN-NEW at all, so counting it there is a permanent zero — every run green,
# including one with twenty warnings.
#
# One tally line carries all six numbers and is printed unconditionally at the end of any
# completed scan (zap-baseline.py:666-668), which is why it is read instead of the
# per-rule `^WARN-NEW: ` lines: those give one of the six. Its absence means the scan did
# not complete, and an unfinished scan reporting zero findings is precisely the failure
# this job exists to avoid — fail closed, the same shape as the Semgrep canary.
tally="$(grep -m1 -E '^FAIL-NEW: ' "$zap_console" || true)"
[ -n "$tally" ] || scanner_error "ZAP printed no result tally — the scan did not complete"

tally_at() { # tally_at <label>
    printf '%s' "$tally" | tr '\t' '\n' | sed -n "s/^$1: //p" | head -1
}
failures="$(tally_at FAIL-NEW)"
findings="$(tally_at WARN-NEW)"
infos="$(tally_at INFO)"
accepted="$(tally_at IGNORE)"
passes="$(tally_at PASS)"

# A tally that parsed to anything other than a number means the format moved under the
# pinned digest. Guessing a zero there would report a clean scan.
for n in "$failures" "$findings" "$infos" "$accepted" "$passes"; do
    [[ "$n" =~ ^[0-9]+$ ]] || scanner_error "ZAP tally line is malformed: ${tally}"
done
```

- [ ] **Step 5: Add the per-level breakdown to the report**

In `.github/actions/dast/scan.sh`, replace:

```bash
{
    echo "=============================="
    echo " DAST: OWASP ZAP baseline"
    echo " Image:  ${DAST_IMAGE}"
    echo " Target: ${target}"
    echo "=============================="
    echo ""
    cat "$zap_out"
} > "$DAST_REPORT_FILE"
```

with:

```bash
{
    echo "=============================="
    echo " DAST: OWASP ZAP baseline"
    echo " Image:  ${DAST_IMAGE}"
    echo " Target: ${target}"
    echo "=============================="
    echo ""
    echo "must fix (FAIL):   ${failures}"
    echo "warnings (WARN):   ${findings}"
    echo "informational:     ${infos}"
    echo "accepted (IGNORE): ${accepted}"
    echo "passed:            ${passes}"
    echo ""
    cat "$zap_out"
} > "$DAST_REPORT_FILE"
```

- [ ] **Step 6: Rewrite the outcome, message and summary**

In `.github/actions/dast/scan.sh`, replace the whole final block from `if [ "$findings" -gt 0 ]; then` to the closing `echo "ZAP baseline — warnings: ${findings}"` with:

```bash
emit failures "$failures"

if [ "$failures" -gt 0 ]; then
    echo "::warning::ZAP baseline reported ${failures} must-fix and ${findings} warning(s). See ${DAST_REPORT_FILE}."
    emit outcome findings
    emit findings "$findings"
    emit_message "🕷 DAST (ZAP): 🔴 ${failures} must-fix · ${findings} warnings"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    summary WARNING "🔴 ${failures} must-fix and ${findings} warning(s) — the register marks these as blocking."
elif [ "$findings" -gt 0 ]; then
    echo "::warning::ZAP baseline reported ${findings} warning(s). See ${DAST_REPORT_FILE}."
    emit outcome findings
    emit findings "$findings"
    emit_message "🕷 DAST (ZAP): 🟡 ${findings} warnings"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    summary WARNING "⚠️ ${findings} baseline warning(s) — review the report."
else
    emit outcome clean
    emit findings 0
    emit_message "🕷 DAST (ZAP): 🟢 clean · ${infos} info · ${accepted} accepted"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    summary NOTE "✅ No must-fix or warning findings. ${infos} informational, ${accepted} accepted by the triage register."
fi

echo "ZAP baseline — must-fix: ${failures}, warnings: ${findings}, info: ${infos}, accepted: ${accepted}, passed: ${passes}"
```

- [ ] **Step 7: Emit `failures` on the two early-exit paths**

In `not_run()` and in `scanner_error()`, immediately after each existing `emit findings 0` line, add:

```bash
    emit failures 0
```

- [ ] **Step 8: Add the `failures` output to `action.yml`**

In `.github/actions/dast/action.yml`, after the `findings` output block, add:

```yaml
  failures:
    description: "Number of FAIL-level ZAP findings — those the triage register marks as must-fix"
    value: ${{ steps.scan.outputs.failures }}
```

And change the `findings` description to:

```yaml
  findings:
    description: "Number of WARN-level ZAP baseline findings"
    value: ${{ steps.scan.outputs.findings }}
```

- [ ] **Step 9: Repair the pre-existing fixtures that have no tally line**

21 scenarios use one of two throwaway console literals whose exact wording carries no meaning, and 7 more rely on the shim's default. All of them now correctly become scanner errors, because a console with no tally line means an unfinished scan. Rather than edit 28 sites by hand, introduce one shared fixture.

In `scripts/test-dast-scan.sh`, immediately after the `pass=0` / `fail=0` lines near the top, add:

```bash
# A completed scan always prints exactly one tally line, so every fixture standing in
# for a completed scan needs one. The scenarios that assert something about counting
# spell their own out; these are the ones where the console content is irrelevant.
ZAP_CLEAN_CONSOLE="PASS: everything
FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 0	WARN-INPROG: 0	INFO: 0	IGNORE: 0	PASS: 40"
```

Then replace both throwaway literals with it:

```bash
sed -i '' 's/SHIM_ZAP_CONSOLE="PASS: everything"/SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE"/g; s/SHIM_ZAP_CONSOLE="PASS: nothing to see"/SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE"/g' scripts/test-dast-scan.sh
```

Verify: `grep -c 'SHIM_ZAP_CONSOLE="\$ZAP_CLEAN_CONSOLE"' scripts/test-dast-scan.sh` must print `21`.

Update the shim default on what is currently line 113 from:

```bash
                printf '%s\n' "${SHIM_ZAP_CONSOLE:-PASS: everything}"
```

to:

```bash
                printf '%s\n' "${SHIM_ZAP_CONSOLE:-PASS: everything
FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 0	WARN-INPROG: 0	INFO: 0	IGNORE: 0	PASS: 40}"
```

Rename the first scenario's assertion from `"a console with no WARN-NEW line counts zero"` to `"a tally of all zeroes counts zero"`.

Two scenarios spell out their own console and must be handled individually. The one at what is currently line 242 already ends in a `WARN-NEW: 3` tally and needs no change, but its assertion name — `only the per-rule WARN-NEW lines are counted, not the tally line` — now describes the opposite of what happens. Rename it to:

```bash
assert_findings "the tally line is the warning count, not the per-rule lines" 3
```

The one at what is currently line 272 is the regression guard for counting the wrong stream. Keep its `-w` markdown fixture exactly as it is and append a tally to its console only:

```bash
SHIM_ZAP_CONSOLE="WARN-NEW: Content Security Policy (CSP) Header Not Set [10038] x 4
WARN-NEW: Missing Anti-clickjacking Header [10020] x 1
WARN-NEW: X-Content-Type-Options Header Missing [10021] x 6
FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 3	WARN-INPROG: 0	INFO: 0	IGNORE: 0	PASS: 40" \
```

Its assertion `a markdown report with alert text but no WARN-NEW still counts 3` stays true and stays valuable: the markdown fixture is full of alert text and free of any tally, so a `scan.sh` that ever reads the `-w` file again fails here.

After the edits, run the harness and read every failure before assuming a fixture is at fault — a scenario failing now may be reporting a real behaviour change rather than a stale fixture.

- [ ] **Step 10: Run the harness to verify it passes**

Run: `./scripts/test-dast-scan.sh`
Expected: PASS. Report the final count in the commit body rather than assuming a number; the fixture repairs in Step 9 make the total depend on what was found there.

- [ ] **Step 11: Prove the tally guard is not vacuous**

Temporarily change `[ -n "$tally" ] || scanner_error ...` to `[ -n "$tally" ] || tally="FAIL-NEW: 0	WARN-NEW: 0	INFO: 0	IGNORE: 0	PASS: 0"`, run `./scripts/test-dast-scan.sh`, and confirm the `a console with no tally line is a scanner error, never clean` scenario fails. Restore and confirm green.

- [ ] **Step 12: Run the full validator**

Run: `./scripts/validate.sh`
Expected: `VALIDATION OK`.

- [ ] **Step 13: Commit**

```bash
git add .github/actions/dast/scan.sh .github/actions/dast/action.yml scripts/test-dast-scan.sh
git commit -m "$(cat <<'EOF'
Count every ZAP severity from the tally line, and fix the exit ladder

Two problems, one of them latent until the triage register gets used.

zap-baseline.py exits 1 when FAIL-level findings are present, and -I does
not suppress that — it gates exit 2 alone. The case statement treated
anything but 0 and 2 as a broken scanner, so the first FAIL entry in the
register would have reddened a trunk build for a finding, collapsing the
distinction between "found something" and "could not run" that the whole
job is built around. The comment claiming -I made exit 1 unreachable was
wrong. Exit 2 is the one -I makes unreachable; it stays handled so that
removing -I later cannot silently turn findings into a broken gate.

The count came from `grep -c '^WARN-NEW: '`, which is one of six numbers
ZAP reports. The single tally line printed at the end of every completed
scan carries all six, so must-fix, warnings, informational, accepted and
passed are now all visible — including on a clean run, because a register
whose suppressions nobody can see is a register nobody audits.

A missing or non-numeric tally is a scanner error. A completed scan always
prints it, so its absence means the scan did not complete, and an
unfinished scan reporting zero findings is the failure this job exists to
avoid.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Documentation, invariants and the skill mirrors

**Files:**
- Modify: `docs/sast-dast.md`
- Modify: `CLAUDE.md`
- Modify: `.agents/skills/nova-ci/SKILL.md`
- Modify: `.claude/skills/nova-ci/SKILL.md`

**Interfaces:**
- Consumes: the behaviour delivered by Tasks 1–3.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Rewrite the ZAP counting section in `docs/sast-dast.md`**

Replace the whole section `### Where the ZAP warning count comes from` (heading at line 307, body running to just before `### The Semgrep canary guard`) with:

````markdown
### Where the ZAP counts come from

`zap-baseline.py` has two output channels and they do not carry the same information.
`-w` writes the traditional **"ZAP Scanning Report" markdown** — `## Summary of Alerts`
and a section per risk level. That file is the human-readable artifact, and it is what
the `.report` is assembled from. But **no count appears in it at all**, so every number
is taken from a `tee` of the console stream.

One line carries all of them, printed unconditionally at the end of any completed scan:

```
FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 11	WARN-INPROG: 0	INFO: 4	IGNORE: 7	PASS: 30
```

`scan.sh` anchors on `^FAIL-NEW: ` and reads all six. `FAIL-NEW` is the must-fix count,
`WARN-NEW` the warning count, and `INFO` / `IGNORE` are what the
[triage register](#recording-a-decision-about-a-finding) suppressed — reported even on a
clean run, because suppressions nobody can see are suppressions nobody audits.

**A missing tally line is a scanner error, never a clean scan.** A completed scan always
prints one, so its absence means the scan did not finish — and an unfinished scan
reporting zero findings is the exact failure this page is built around. The same applies
to a tally whose numbers do not parse: the format would have moved under the pinned
digest, and guessing zero there reports a clean scan that never happened.

This is not a detail. `-I` makes the script exit `0` even with warnings present, so the
exit code carries no signal either; counting the wrong stream leaves **both** channels
dead and every run reports `🟢 clean` with `findings=0`, including one where ZAP found
twenty warnings. The harness carries a scenario whose markdown report is full of alert
text and free of any count, so a `scan.sh` that ever reads the `-w` file again fails.

`${PIPESTATUS[0]}` matters for the same reason: it is ZAP's own exit status,
unambiguously. Plain `$?` after the pipe happens to give the same answer today only
because `pipefail` is set — it would silently become `tee`'s status the moment that
changed, and it reports `tee`'s status whenever `tee` itself fails.

The exit ladder is read from the same source rather than assumed
(`zap-baseline.py:697-708`):

| Exit | Meaning | Treated as |
| --- | --- | --- |
| 0 | passes only | clean |
| 1 | `FAIL`-level findings present | **findings** — `-I` does *not* suppress this |
| 2 | warnings with `-I` absent | findings — unreachable while `-I` is passed |
| 3 | an exception, or no rule ran at all | scanner error |

Exit `1` is the one to be careful with. `-I` gates exit `2` alone, so the moment the
triage register gains its first `FAIL` entry, an exit-`1` run is a *finding* — and
treating it as a broken scanner would red a trunk build for one.

The console log lives under `RUNNER_TEMP`, is deleted by the same `EXIT` trap that
removes the temporary env file, and is never uploaded — it is raw output about a
container booted with the product repository's own environment.

### Recording a decision about a finding

A scanner that can only ever add to its count is one people stop reading. Both scanners
have a way to write down "this is accepted" or "this must be fixed", and both keep that
decision in version control next to a reason.

**ZAP — [`zap-baseline.conf`](../.github/actions/dast/zap-baseline.conf).** Every rule
defaults to `WARN`; an entry overrides that for one rule ID. The grammar is
TAB-separated with at least three fields:

```
<rule_id>	<LEVEL>	<why this decision was made, and who accepted it>
<id>,<id>	OUTOFSCOPE	<regex matched against the alert URL>
```

| Level | Means |
| --- | --- |
| `FAIL` | must be fixed — counted and reported separately from warnings |
| `WARN` | the default; no entry needed |
| `INFO` | noted, out of the warning count, still in the report |
| `IGNORE` | accepted risk — the reason column is not optional |
| `PASS` | treated as passing |

The file ships with no entries, so it changes nothing until someone adds a line. Adding
one is a risk-acceptance decision, not a CI change.

Rule IDs are not written from memory. Generate the list the pinned image actually loads:

```bash
docker run --rm -v "$PWD:/zap/wrk:rw" ghcr.io/zaproxy/zaproxy:stable \
    zap-baseline.py -t http://example.com -g zap-rules.conf
```

`scan.sh` validates the shape of every line before anything is booted — at least two
tabs, and a level from the set above — and treats a malformed or missing register as a
broken gate. **It cannot validate the IDs.** ZAP reports alert counts per bucket, never
which configured IDs matched, so a well-formed line naming a rule that does not exist is
silently inert and nothing detects it. That limit is procedural, not mechanical: use the
generated list.

**Semgrep — inline `nosemgrep`, in the product repository.**

```ts
// nosemgrep: javascript.express.security.audit.xss.direct-response-write — value is a
// UUID from the router, validated by the Joi schema above. NC2-XXXX.
res.write(req.params.id)
```

Per-finding, next to the code it describes, reviewed in the pull request that introduces
it. This is the analogue of a `.gitleaksignore` fingerprint. A path-scoped
`.semgrepignore` is deliberately **not** used: it is the blanket `ignore tests/**` that
[secret detection](secret-detection.md) already rejected, and it hides whole directories
rather than one decision.
````

- [ ] **Step 2: Correct the Semgrep severity claims across `docs/sast-dast.md`**

Run `rg -n 'ERROR|severity' docs/sast-dast.md` and fix every line asserting that findings are counted at `ERROR` only. Three known sites:

- the outcomes table around line 103 — the SAST row must read that `ERROR` and `WARNING` are both counted;
- the notification section around line 564 — the example line becomes `🔍 SAST (Semgrep): 🟡 3 error · 12 warning`;
- the canary-guard section around line 331 — item 6 refers to the finding count; it stays correct but must not imply a single severity.

Delete every mention of the `severity` input, which no longer exists. Add one sentence stating that `INFO` is counted for the job summary but kept out of the report body, because the registry packs emit it liberally and it would bury the two levels that carry a decision.

- [ ] **Step 3: Check the `docs/` page opens with an asset and that no diagram now lies**

`validate.sh` fails if a page under `docs/` has no asset. This task adds sections to an existing page, so no new asset is required — confirm `docs/sast-dast.md` still opens with its existing `assets/readme/` image, and read that image to check it makes no claim about counting or severities that these changes falsify. If it does, regenerate it with the `beautify-github-readme` skill and verify by rendering at `rsvg-convert -w 900` and `-w 360`, never by computing text widths.

- [ ] **Step 4: Add the new invariants to `CLAUDE.md`**

Under **Code scanning (SAST/DAST)**, add:

- Semgrep reports `ERROR` and `WARNING` as two counts and lists both. Do not reintroduce a single-severity filter: the old one was an exact equality that hid 12 `WARNING` findings on `novatalks.core` from the count *and* from the published report.
- Take the ZAP counts from the single tally line (`^FAIL-NEW: `), never from the per-rule `WARN-NEW:` lines, and treat a missing or non-numeric tally as a scanner error. The line is printed unconditionally by any completed scan, so its absence means the scan did not finish.
- Keep `0|1|2` in the ZAP exit-code `case`. Exit **1** is `FAIL`-level findings and `-I` does not suppress it — `-I` gates exit 2 alone. Moving 1 back into the error arm reds a trunk build for a finding.
- `.github/actions/dast/zap-baseline.conf` is the triage register. Keep the reason column mandatory. Adding an entry is a risk-acceptance decision, not a CI change. A mistyped rule ID is silently inert; `scan.sh` validates line shape and levels only, and cannot validate IDs.

- [ ] **Step 5: Fix the stale harness counts in `CLAUDE.md`**

Line 123 says `scripts/test-sast-scan.sh, 14 checks` and `scripts/test-dast-scan.sh, 36 checks`. Both have been wrong since before this plan — the real numbers on the parent branch are 19 and 91. Replace them with the counts the harnesses print after Task 3.

- [ ] **Step 6: Mirror both SKILL.md files**

Apply the same additions to `.agents/skills/nova-ci/SKILL.md` and copy it verbatim to `.claude/skills/nova-ci/SKILL.md`:

```bash
cp .agents/skills/nova-ci/SKILL.md .claude/skills/nova-ci/SKILL.md
```

`validate.sh` fails if the two diverge.

- [ ] **Step 7: Run the full validator**

Run: `./scripts/validate.sh`
Expected: `VALIDATION OK`, including the `.agents` ↔ `.claude` mirror check.

- [ ] **Step 8: Review the whole diff**

Run:

```bash
git diff main... -- .github/workflows .github/actions security scripts docs README.md AGENTS.md CLAUDE.md .agents/skills/nova-ci/SKILL.md .claude/skills/nova-ci/SKILL.md
```

Read it for claims that are no longer true — especially any comment or doc line asserting something about `-I`, exit codes, or which severities are counted.

- [ ] **Step 9: Commit**

```bash
git add docs/sast-dast.md CLAUDE.md .agents/skills/nova-ci/SKILL.md .claude/skills/nova-ci/SKILL.md
git commit -m "$(cat <<'EOF'
Document the triage register and correct the scanner invariants

Records what changed and, more importantly, the two claims that were
wrong: that -I makes zap-baseline.py's exit 1 unreachable, and that the
warning count could come from the per-rule lines. Both are now invariants
with the upstream line numbers behind them.

Also corrects the harness counts in CLAUDE.md, which have been stale since
the DAST repository rollout.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Verification before the pull request

- [ ] `./scripts/validate.sh` ends `VALIDATION OK`
- [ ] Both harnesses green, with counts matching what the commit bodies claim
- [ ] `git log --format='%(trailers:key=Co-Authored-By)' main..` shows a trailer on every commit
- [ ] No product repository was modified
- [ ] A live `scan` tag run on one repository confirms A1 — that the pinned ZAP digest prints the tally line in the expected format, and that `-c` with an entry-free register changes nothing. `novatalks.geoip-api` is the cheapest target: no database, no NATS, fastest boot.
