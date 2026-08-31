# SAST and DAST Scanning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Semgrep OSS as SAST across all standard build repositories and OWASP ZAP baseline as DAST on `novatalks.ui` and `novatalks.core`, each producing its own report on the existing build release and its own status line in the notifier.

**Architecture:** Two composite actions (`.github/actions/semgrep/`, `.github/actions/dast/`), each a thin `action.yml` over a `scan.sh` that holds all logic and composes its own notifier text, mirroring `.github/actions/gitleaks/`. Two new jobs in `ci-build-ntk-on-push-tags-build.yaml` run sequentially after `trivy-scan`. Each `scan.sh` gets an offline harness under `scripts/`, registered in `validate.sh`.

**Tech Stack:** GitHub Actions composite actions, bash, `jq`, Docker, Semgrep OSS (container), OWASP ZAP stable (container), Hetzner self-hosted runners.

**Spec:** [`docs/superpowers/specs/2026-08-28-sast-dast-scanning.md`](../specs/2026-08-28-sast-dast-scanning.md)

## Global Constraints

- Branch: `feat/sast-dast-scanning`, already created from `main`.
- Both scanner containers are pinned by **version and SHA-256 digest**, never `latest` (spec D5; mirrors the Gitleaks pin invariant in `CLAUDE.md`).
- **Findings warn; a scanner that could not run reds the job** (spec D8). An application that fails to boot is a **loud skip**, not red and not silence (spec D9).
- `scan.sh` composes the notifier text; workflow YAML only interpolates it (NC2-2742 D6).
- Every `scan.sh` decision branch gets a scenario in its harness **in the same commit**.
- Trunk means `main`, `master` or `development` throughout.
- Never edit product-repository caller workflows.
- Do not rename the `secret-scan` check, do not touch the `trivy-scan` gate, do not add `continue-on-error` to any test job.
- Run `./scripts/validate.sh` before every commit; it must print `VALIDATION OK`.
- Commit messages: imperative, sentence case, no `feat:`/`fix:` prefix (house style), body explains *why*, and end with:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

## File Structure

| File | Responsibility |
| --- | --- |
| `.github/actions/semgrep/action.yml` | Pin the Semgrep image; pass env into `scan.sh`; expose `outcome`, `findings`, `message`, `report_file` |
| `.github/actions/semgrep/scan.sh` | Run Semgrep, guard that the engine really ran, count by severity, write the `.report`, write the job summary, compose the notifier line |
| `.github/actions/semgrep/canary.yaml` | One local rule matched against a generated fixture, proving the rule engine executed |
| `.github/actions/dast/action.yml` | Pin the ZAP image; take image/port/health/timeout inputs; expose the same four outputs |
| `.github/actions/dast/scan.sh` | Bring up postgres/redis/app, wait for health, run ZAP baseline, clean up, resolve the four-way outcome, compose the notifier line |
| `scripts/test-sast-scan.sh` | Offline scenarios for the Semgrep `scan.sh` |
| `scripts/test-dast-scan.sh` | Offline scenarios for the DAST `scan.sh`, with `docker` stubbed on `PATH` |
| `.github/workflows/ci-build-ntk-on-push-tags-build.yaml` | `IS_TRUNK` output, `sast-scan` job, `dast-scan` job, two notifier lines |
| `.github/workflows/ci-build-create-runner.sh` | `medium` sizing whenever DAST will run on `novatalks.core` |
| `scripts/validate.sh` | Register both harnesses; extend the direct-invocation guard to Semgrep and ZAP |
| `docs/sast-dast.md` + `assets/readme/sast-dast.svg` | The human-facing page and its required diagram |

---

### Task 1: Semgrep action, scan.sh and harness

**Files:**
- Create: `.github/actions/semgrep/action.yml`
- Create: `.github/actions/semgrep/scan.sh`
- Create: `.github/actions/semgrep/canary.yaml`
- Create: `scripts/test-sast-scan.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `scan.sh` reads env `SEMGREP_IMAGE`, `SEMGREP_CONFIGS` (space-separated), `SEMGREP_SEVERITY`, `SEMGREP_SRC`, `SEMGREP_REPORT_FILE`, `SEMGREP_ACTION_ROOT`, `REPORT_URL`, and writes to `$GITHUB_OUTPUT` the keys `outcome` (`clean|findings|error`), `findings` (integer), `message` (heredoc-delimited). Task 2 reads exactly these names.

- [ ] **Step 1: Establish what Semgrep does when its config cannot be resolved**

Spec assumption A4 decides the shape of the guard, so settle it before writing it.

```bash
docker run --rm -v "$PWD:/src" -w /src semgrep/semgrep:1.99.0 \
  semgrep scan --config=p/definitely-not-a-real-pack --json --metrics=off > /tmp/a.json; echo "exit=$?"
jq '{errors: (.errors | length), scanned: (.paths.scanned | length)}' /tmp/a.json
```

Record the exit code and whether `paths.scanned` is populated in the commit body. If the exit code is `>= 2`, the exit-code check alone is sufficient and the canary is cheap insurance. If it is `0` or `1` with an empty `errors` array, the canary is load-bearing. Either way the implementation below stays the same — only the commit body's justification changes.

- [ ] **Step 2: Write the canary rule and the failing harness**

`.github/actions/semgrep/canary.yaml`:

```yaml
# Proves the rule engine actually executed. Semgrep reporting "clean" is
# indistinguishable from Semgrep having loaded zero rules — the same trap as
# `gitleaks git --log-opts` exiting 0 on an unresolvable range. scan.sh writes a
# fixture containing the marker below into a temp dir it adds to the scan target,
# and treats a missing canary hit as an error, never as a clean run.
rules:
  - id: nova-ci-semgrep-canary
    languages: [generic]
    severity: INFO
    message: nova.ci Semgrep canary
    pattern-regex: NOVA_CI_SEMGREP_CANARY_MARKER
```

`scripts/test-sast-scan.sh`:

```bash
#!/usr/bin/env bash
#
# Self-check for .github/actions/semgrep/scan.sh.
#
# scan.sh decides whether a build reports SAST findings, a clean scan, or a broken
# scanner — and the difference between the last two is the whole point, so every
# branch gets a scenario. It runs offline: `docker` is stubbed on PATH and answers
# with canned Semgrep JSON, so no image is pulled and no network is touched.
#
# Usage: ./scripts/test-sast-scan.sh
# Exit status: 0 all scenarios passed, 1 a scenario failed.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION_DIR="$ROOT/.github/actions/semgrep"
SCAN="$ACTION_DIR/scan.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/src"

pass=0
fail=0

# docker shim: emit $SHIM_JSON to the file semgrep would write, exit $SHIM_RC.
cat > "$WORK/bin/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s' "${SHIM_JSON:-{\}}" > "${SHIM_OUT:?SHIM_OUT unset}"
exit "${SHIM_RC:-0}"
SHIM
chmod +x "$WORK/bin/docker"

# Semgrep JSON with a given list of severities, plus the canary hit unless told not to.
semgrep_json() { # semgrep_json <canary:yes|no> [severity]...
    local canary="$1"; shift
    local results="[]" sev
    if [ "$canary" = yes ]; then
        results=$(jq -c '. + [{check_id: "nova-ci-semgrep-canary", extra: {severity: "INFO"}}]' <<<"$results")
    fi
    for sev in "$@"; do
        results=$(jq -c --arg s "$sev" \
            '. + [{check_id: "rule.x", path: "src/a.ts", start: {line: 3}, extra: {severity: $s, message: "m"}}]' \
            <<<"$results")
    done
    jq -c --argjson r "$results" \
        '{results: $r, errors: [], paths: {scanned: ["src/a.ts"]}}' <<<'{}'
}

expect() { # expect <name> <expected-outcome> <expected-findings>
    local name="$1" want_outcome="$2" want_findings="$3"
    local out="$WORK/output" summary="$WORK/summary" report="$WORK/report"
    : >"$out"; : >"$summary"; : >"$report"

    set +e
    PATH="$WORK/bin:$PATH" \
    SEMGREP_IMAGE="semgrep/semgrep@sha256:deadbeef" \
    SEMGREP_CONFIGS="p/typescript" \
    SEMGREP_SEVERITY="ERROR" \
    SEMGREP_SRC="$WORK/src" \
    SEMGREP_REPORT_FILE="$report" \
    SEMGREP_ACTION_ROOT="$ACTION_DIR" \
    RUNNER_TEMP="$WORK" \
    REPORT_URL="https://example.invalid/r" \
    GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$summary" \
    SHIM_OUT="$WORK/semgrep.json" \
        bash "$SCAN" >"$WORK/log" 2>&1
    local rc=$?
    set -e

    local got_outcome got_findings
    got_outcome=$(sed -n 's/^outcome=//p' "$out")
    got_findings=$(sed -n 's/^findings=//p' "$out")

    if [ "$got_outcome" = "$want_outcome" ] && [ "$got_findings" = "$want_findings" ]; then
        echo "ok   $name"; pass=$((pass + 1))
    else
        echo "FAIL $name"
        echo "     expected: outcome=$want_outcome findings=$want_findings"
        echo "     actual:   outcome=$got_outcome findings=$got_findings (rc=$rc)"
        sed 's/^/     /' "$WORK/log"
        fail=$((fail + 1))
    fi
}

assert_report() { # assert_report <name> <grep-pattern> [--absent]
    local name="$1" pat="$2" mode="${3:-}"
    if grep -q "$pat" "$WORK/report"; then
        [ "$mode" = "--absent" ] && { echo "FAIL $name"; fail=$((fail + 1)); return; }
    else
        [ "$mode" != "--absent" ] && { echo "FAIL $name"; fail=$((fail + 1)); return; }
    fi
    echo "ok   $name"; pass=$((pass + 1))
}

echo "=== semgrep scan.sh — $SCAN ==="

SHIM_JSON="$(semgrep_json yes)" SHIM_RC=0 \
    expect "clean scan reports clean" clean 0

SHIM_JSON="$(semgrep_json yes ERROR ERROR)" SHIM_RC=1 \
    expect "two ERROR findings are counted" findings 2

SHIM_JSON="$(semgrep_json yes WARNING)" SHIM_RC=1 \
    expect "WARNING is not counted at ERROR severity" clean 0

SHIM_JSON="$(semgrep_json no)" SHIM_RC=0 \
    expect "a missing canary is an error, never a clean run" error 0

SHIM_JSON="$(semgrep_json yes)" SHIM_RC=2 \
    expect "a semgrep crash is an error" error 0

SHIM_JSON='{"results":[],"errors":[],"paths":{"scanned":[]}}' SHIM_RC=0 \
    expect "scanning zero files is an error, never a clean run" error 0

SHIM_JSON='not json at all' SHIM_RC=0 \
    expect "unparseable output is an error" error 0

SHIM_JSON="$(semgrep_json yes ERROR)" SHIM_RC=1 \
    expect "single finding" findings 1
assert_report "report names the rule" "rule.x"
assert_report "report never contains the canary" "nova-ci-semgrep-canary" --absent

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 3: Run the harness and confirm it fails**

Run: `./scripts/test-sast-scan.sh`
Expected: FAIL — `.github/actions/semgrep/scan.sh` does not exist yet, every scenario errors.

- [ ] **Step 4: Write `scan.sh`**

```bash
#!/usr/bin/env bash
#
# Run Semgrep OSS over the checked-out source and turn the result into three things:
# a .report file, a job summary, and a ready-to-send notifier line.
#
# Fails closed on anything that is not a clean answer. "Semgrep found nothing" and
# "Semgrep never ran" produce identical empty result sets, so this script refuses to
# call the second one clean: the canary rule must fire and at least one file must
# have been scanned, or the outcome is `error` and the job goes red.
#
set -euo pipefail

: "${SEMGREP_IMAGE:?}" "${SEMGREP_CONFIGS:?}" "${SEMGREP_SEVERITY:?}"
: "${SEMGREP_SRC:?}" "${SEMGREP_REPORT_FILE:?}" "${SEMGREP_ACTION_ROOT:?}"

CANARY_MARKER="NOVA_CI_SEMGREP_CANARY_MARKER"
json="${RUNNER_TEMP:-/tmp}/semgrep.json"

emit() { # emit <key> <value>
    printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/null}"
}

emit_message() { # emit_message <text>
    {
        echo "message<<SEMGREP_EOF"
        printf '%s\n' "$1"
        echo "SEMGREP_EOF"
    } >> "${GITHUB_OUTPUT:-/dev/null}"
}

finish_error() { # finish_error <reason>
    local reason="$1"
    echo "::error::SAST scan could not complete: ${reason}"
    emit outcome error
    emit findings 0
    emit_message "🔍 SAST (Semgrep): ❌ scan failed — ${reason}"
    {
        echo "## 🔍 SAST (Semgrep)"
        echo ""
        echo "> [!CAUTION]"
        echo "> Scan did not complete: ${reason}. This is a broken gate, not a clean result."
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    exit 2
}

# The canary lives in a directory of its own that is scanned alongside the source, so
# a repository with zero matching files still proves the engine ran.
canary_dir="${RUNNER_TEMP:-/tmp}/semgrep-canary"
mkdir -p "$canary_dir"
printf '%s\n' "$CANARY_MARKER" > "$canary_dir/canary.txt"

config_args=()
for cfg in $SEMGREP_CONFIGS; do
    config_args+=(--config="$cfg")
done
config_args+=(--config=/canary/canary.yaml)

set +e
docker run --rm \
    -v "${SEMGREP_SRC}:/src:ro" \
    -v "${canary_dir}:/canary-src:ro" \
    -v "${SEMGREP_ACTION_ROOT}/canary.yaml:/canary/canary.yaml:ro" \
    -v "${RUNNER_TEMP:-/tmp}:/out" \
    -w /src \
    "$SEMGREP_IMAGE" \
    semgrep scan "${config_args[@]}" \
        --json --metrics=off --quiet --no-git-ignore \
        --output /out/semgrep.json \
        /src /canary-src
rc=$?
set -e

# /out is RUNNER_TEMP, so the container's output path is $json on the host. A missing
# file means the container never got far enough to write one.
[ -s "$json" ] || finish_error "Semgrep produced no output (exit ${rc})"
[ "$rc" -le 1 ] || finish_error "Semgrep exited ${rc}"
jq -e . "$json" >/dev/null 2>&1 || finish_error "Semgrep output is not valid JSON"

scanned=$(jq '.paths.scanned | length' "$json")
[ "$scanned" -gt 0 ] || finish_error "Semgrep scanned zero files"

canary_hits=$(jq '[.results[] | select(.check_id | test("nova-ci-semgrep-canary"))] | length' "$json")
[ "$canary_hits" -gt 0 ] || finish_error "the canary rule did not fire — the rule engine did not run"

findings=$(jq --arg sev "$SEMGREP_SEVERITY" \
    '[.results[] | select(.extra.severity == $sev)] | length' "$json")

{
    echo "=============================="
    echo " SAST: Semgrep"
    echo " Image:    ${SEMGREP_IMAGE}"
    echo " Configs:  ${SEMGREP_CONFIGS}"
    echo " Severity: ${SEMGREP_SEVERITY}"
    echo "=============================="
    echo ""
    echo "=== ${SEMGREP_SEVERITY} findings: ${findings} ==="
    echo ""
    jq -r --arg sev "$SEMGREP_SEVERITY" \
        '.results[] | select(.extra.severity == $sev)
         | "\(.path):\(.start.line)  [\(.check_id)]\n    \(.extra.message)\n"' "$json"
} > "$SEMGREP_REPORT_FILE"

if [ "$findings" -gt 0 ]; then
    outcome=findings
    echo "::warning::Semgrep found ${findings} ${SEMGREP_SEVERITY} finding(s). See ${SEMGREP_REPORT_FILE}."
    message="🔍 SAST (Semgrep): 🟡 ${findings} ${SEMGREP_SEVERITY}"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    alert=WARNING
    headline="⚠️ ${findings} ${SEMGREP_SEVERITY} finding(s) — review the report."
else
    outcome=clean
    message="🔍 SAST (Semgrep): 🟢 clean"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    alert=NOTE
    headline="✅ No ${SEMGREP_SEVERITY} findings."
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
    echo "- Report: ${REPORT_URL:-not published}"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

emit outcome "$outcome"
emit findings "$findings"
emit_message "$message"
echo "Semgrep results — ${SEMGREP_SEVERITY}: ${findings} (outcome: ${outcome})"
```

- [ ] **Step 5: Run the harness and confirm it passes**

Run: `chmod +x .github/actions/semgrep/scan.sh scripts/test-sast-scan.sh && ./scripts/test-sast-scan.sh`
Expected: `10 passed, 0 failed`.

If the canary-hit filter needs the real Semgrep `check_id` shape (it is prefixed with the config path when a rule comes from a file), fix the `test(...)` pattern rather than loosening the guard.

- [ ] **Step 6: Write `action.yml`**

```yaml
name: "Semgrep SAST scan"
description: "Static security analysis of the checked-out source with Semgrep OSS and the central rule packs"

inputs:
  configs:
    description: "Space-separated Semgrep configs"
    required: false
    default: "p/typescript p/nodejs p/owasp-top-ten"
  severity:
    description: "Severity counted as a finding"
    required: false
    default: "ERROR"
  report-file:
    description: "Path the .report is written to"
    required: true
  report-url:
    description: "Public URL the report will be published at, for the notifier line"
    required: false
    default: ""

outputs:
  outcome:
    description: "clean | findings | error — a notifier must distinguish findings from a broken scanner"
    value: ${{ steps.scan.outputs.outcome }}
  findings:
    description: "Number of findings at the configured severity"
    value: ${{ steps.scan.outputs.findings }}
  message:
    description: "Ready-to-send notifier text"
    value: ${{ steps.scan.outputs.message }}

runs:
  using: composite
  steps:
    # Pinned by version AND digest, for the same reason Gitleaks is: a tag can be
    # moved, and `latest` would let an upstream change silently alter what a security
    # gate reports. To upgrade: bump the tag, then re-read the digest with
    #   docker buildx imagetools inspect semgrep/semgrep:<tag>
    - name: Scan source
      id: scan
      shell: bash
      env:
        SEMGREP_IMAGE: "semgrep/semgrep:1.99.0@sha256:REPLACE_WITH_DIGEST_FROM_STEP_7"
        SEMGREP_CONFIGS: ${{ inputs.configs }}
        SEMGREP_SEVERITY: ${{ inputs.severity }}
        SEMGREP_SRC: ${{ github.workspace }}
        SEMGREP_REPORT_FILE: ${{ inputs.report-file }}
        SEMGREP_ACTION_ROOT: ${{ github.action_path }}
        REPORT_URL: ${{ inputs.report-url }}
      run: |
        set -euo pipefail
        bash "${SEMGREP_ACTION_ROOT}/scan.sh"
```

- [ ] **Step 7: Resolve and substitute the real digest**

Run:

```bash
docker buildx imagetools inspect semgrep/semgrep:1.99.0 --format '{{.Manifest.Digest}}'
```

Replace `REPLACE_WITH_DIGEST_FROM_STEP_7` with the returned `sha256:…`. Then confirm nothing unpinned survived:

```bash
grep -n 'semgrep/semgrep' .github/actions/semgrep/action.yml
```

Expected: exactly one line, containing both `:1.99.0` and `@sha256:`.

- [ ] **Step 8: Validate and commit**

```bash
./scripts/validate.sh
git add .github/actions/semgrep scripts/test-sast-scan.sh
git commit
```

Message: `Add Semgrep SAST behind a composite action with a canary guard`. Body must record the Step 1 finding — what Semgrep actually does with an unresolvable config — because that is the evidence the canary guard rests on.

---

### Task 2: Wire the sast-scan job and its notifier line

**Files:**
- Modify: `.github/workflows/ci-build-ntk-on-push-tags-build.yaml` — `build-image` outputs (~line 318), new job after `trivy-scan` (~line 790), `notify-telegram` (~line 792)

**Interfaces:**
- Consumes: from Task 1, action path `./.github/actions/semgrep` with inputs `report-file`, `report-url` and outputs `outcome`, `findings`, `message`.
- Produces: job `sast-scan` with outputs `OUTCOME`, `FINDINGS`, `MESSAGE`, `SCANNED`; `build-image` output `IS_TRUNK` (`'true'`/`'false'`). Tasks 6 and 7 reuse `IS_TRUNK`.

- [ ] **Step 1: Add the `IS_TRUNK` output to `build-image`**

In the `Prepare Vars` step (`ci-build-ntk-on-push-tags-build.yaml:337-354`), after `short_ref_name` is sanitised and before the `echo` block, add:

```bash
          # Trunk drives every scan gate. Resolved once here, where SHORT_REF_NAME is
          # already known, because a job-level `if` cannot reach into another job's step.
          case "$short_ref_name" in
            main|master|development) is_trunk=true ;;
            *)                       is_trunk=false ;;
          esac
```

and add to the same `echo` block:

```bash
          echo "IS_TRUNK=${is_trunk}" | tee -a $GITHUB_ENV $GITHUB_OUTPUT
```

In the job's `outputs:` map (around line 318), add:

```yaml
      IS_TRUNK: ${{ steps.prep.outputs.IS_TRUNK }}
```

- [ ] **Step 2: Add the `sast-scan` job**

Insert after the `trivy-scan` job ends and before `notify-telegram`:

```yaml
  sast-scan:
    name: SAST Scan
    runs-on: ${{ inputs.runner_labels  || 'self-hosted' }}
    environment: ${{ inputs.environment }}
    permissions:
      contents: write
    # Same gate as the image scan: a report is only useful where there is a release to
    # attach it to, and pull requests never build one. Sequential after trivy-scan —
    # three parallel scan jobs would only queue against the per-size cap of 2.
    if: >-
      ${{ always()
      && github.event_name != 'pull_request'
      && needs.build-image.result == 'success'
      && (needs.build-image.outputs.IS_TRUNK == 'true' || startsWith(github.ref_name, 'scan')) }}
    needs: [build-image, trivy-scan]
    outputs:
      SCANNED: 'true'
      OUTCOME: ${{ steps.semgrep.outputs.outcome }}
      FINDINGS: ${{ steps.semgrep.outputs.findings }}
      MESSAGE: ${{ steps.semgrep.outputs.message }}
    env:
      REPORT_FILE: semgrep-${{ needs.build-image.outputs.REP_NAME }}-${{ needs.build-image.outputs.SHORT_REF_NAME }}${{ needs.build-image.outputs.IMAGE_SUFFIX }}-${{ needs.build-image.outputs.SHORT_SHA }}.report
      RELEASE_TAG: TRIVY.SCAN_${{ needs.build-image.outputs.RELEASE }}_${{ needs.build-image.outputs.SHORT_REF_NAME }}${{ needs.build-image.outputs.IMAGE_SUFFIX }}_${{ needs.build-image.outputs.SHORT_SHA }}
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Install Docker
        uses: novaitdevteam/nova.ci/.github/actions/install-docker@main

      - name: Semgrep
        id: semgrep
        uses: novaitdevteam/nova.ci/.github/actions/semgrep@main
        with:
          report-file: ${{ env.REPORT_FILE }}
          report-url: ${{ github.server_url }}/${{ github.repository }}/releases/download/${{ env.RELEASE_TAG }}/${{ env.REPORT_FILE }}

      - name: Upload report artifact
        if: ${{ always() && hashFiles(env.REPORT_FILE) != '' }}
        uses: actions/upload-artifact@v4
        with:
          name: ${{ env.REPORT_FILE }}
          path: ${{ env.REPORT_FILE }}

      # Upsert into the release trivy-scan already created for this build: one release
      # per build carrying every scanner's report. The TRIVY.SCAN_ prefix is historical
      # — see docs/container-scanning.md.
      - name: Publish report release
        if: ${{ always() && hashFiles(env.REPORT_FILE) != '' }}
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ env.RELEASE_TAG }}
          name: ${{ env.RELEASE_TAG }}
          prerelease: true
          files: ${{ env.REPORT_FILE }}
```

- [ ] **Step 3: Add the notifier line**

In `notify-telegram`, extend `needs` to `[build-image, linter, trivy-scan, unit-test, sast-scan]`, then add after the `Compose Trivy line` step:

```yaml
      - name: Compose SAST line
        id: sast_line
        env:
          RESULT: ${{ needs.sast-scan.result }}
          SCANNED: ${{ needs.sast-scan.outputs.SCANNED }}
          MESSAGE: ${{ needs.sast-scan.outputs.MESSAGE }}
        run: |
          set -euo pipefail

          # A job that died before scan.sh ran leaves MESSAGE empty. Silence there would
          # read as a clean scan, so say so explicitly instead.
          if [[ "$SCANNED" != "true" ]]; then
            line="🔍 SAST (Semgrep): ⏭️ skipped (no scan trigger)"
          elif [[ -n "$MESSAGE" ]]; then
            line="$MESSAGE"
          else
            line="🔍 SAST (Semgrep): ❌ scan job failed before reporting (${RESULT})"
          fi

          {
            echo "value<<EOF"
            printf '%s\n' "$line"
            echo "EOF"
          } >> "$GITHUB_OUTPUT"
```

and insert `${{ steps.sast_line.outputs.value }}` into the `if_true` message body immediately after `${{ steps.trivy_line.outputs.value }}`, separated by a blank line.

- [ ] **Step 4: Validate**

Run: `./scripts/validate.sh`
Expected: `VALIDATION OK`. The YAML parse check is what catches an indentation slip in a 900-line workflow; do not skip it.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci-build-ntk-on-push-tags-build.yaml
git commit
```

Message: `Run Semgrep on trunk builds and report it alongside Trivy`.

---

### Task 3: Register the SAST harness and guard direct invocation

**Files:**
- Modify: `scripts/validate.sh` — after the "Secret scan self-check" section (~line 140) and inside the "Gitleaks invocation" section (~line 142-160)

**Interfaces:**
- Consumes: `scripts/test-sast-scan.sh` from Task 1.
- Produces: nothing consumed by later tasks; Task 5 extends the same guard for ZAP.

- [ ] **Step 1: Add the harness section**

Insert after the Secret scan self-check section:

```bash
section "SAST scan self-check"
# Semgrep's scan.sh decides whether a build reports findings, a clean scan or a broken
# scanner, and conflating the last two is the failure this guard exists to prevent.
# The harness stubs docker, so it needs no image and no network.
if command -v jq >/dev/null 2>&1; then
  if out="$(./scripts/test-sast-scan.sh 2>&1)"; then
    printf '%s\n' "$out" | tail -1
    echo "OK: all semgrep scan.sh scenarios passed"
  else
    printf '%s\n' "$out"
    echo "ERROR: semgrep scan.sh self-check failed"
    fail=1
  fi
else
  echo "skip: jq not installed"
fi
```

- [ ] **Step 2: Extend the invocation guard**

Rename the section from `"Gitleaks invocation"` to `"Scanner invocation"` and add, after the existing Gitleaks check:

```bash
# Same argument as Gitleaks: the pin, the canary guard and the harness all live in
# .github/actions/semgrep, and an inline `docker run semgrep` bypasses all three at once.
semgrep_offenders="$(grep -nE 'semgrep +scan\b|uses:.*semgrep' .github/workflows/*.yaml \
  | grep -vE 'uses:.*/\.github/actions/semgrep(@|$)' \
  | grep -v ':[0-9]*: *#' || true)"
if [ -z "$semgrep_offenders" ]; then
  echo "OK: every workflow scans through .github/actions/semgrep"
else
  printf '%s\n' "$semgrep_offenders" | sed 's/^/       /'
  echo "ERROR: these lines invoke Semgrep directly; use .github/actions/semgrep"
  fail=1
fi
```

- [ ] **Step 3: Prove the guard works by breaking it**

The repo's own convention is to verify a check by breaking it, not by assuming it works (see the `Turn the docs-asset conventions into checks` commit).

```bash
printf '\n# semgrep scan --config=p/x\n' >> .github/workflows/ci-self-validate.yaml
./scripts/validate.sh; echo "rc=$?"
```

Expected: the comment line is ignored (the guard skips `#` lines) — `VALIDATION OK`. Now make it real:

```bash
sed -i.bak 's|^# semgrep scan --config=p/x|      run: semgrep scan --config=p/x|' .github/workflows/ci-self-validate.yaml
./scripts/validate.sh; echo "rc=$?"
```

Expected: non-zero, with `ERROR: these lines invoke Semgrep directly`. Then restore:

```bash
mv .github/workflows/ci-self-validate.yaml.bak .github/workflows/ci-self-validate.yaml
git diff --stat .github/workflows/ci-self-validate.yaml
```

Expected: empty diff.

- [ ] **Step 4: Validate and commit**

```bash
./scripts/validate.sh
git add scripts/validate.sh
git commit
```

Message: `Cover the Semgrep scanner in the validation harness`. Body records that the guard was verified by breaking it.

---

### Task 4: Boot probe for novatalks.core and novatalks.ui

**Files:**
- Create (temporary): `.github/workflows/ci-dast-boot-probe.yaml`
- Modify: `docs/superpowers/specs/2026-08-28-sast-dast-scanning.md` — the "Assumptions to establish" table

**Interfaces:**
- Consumes: nothing.
- Produces: confirmed values for `port`, `health path` and `boot timeout` per repository, plus a yes/no on A1 and A2. Task 5 hard-codes nothing without them; Task 6 needs A3.

This task's deliverable is an **answer**, not shipped code. The workflow is throwaway and is deleted in Step 5.

- [ ] **Step 1: Write the probe workflow**

```yaml
name: DAST Boot Probe (temporary)

# Throwaway. Settles spec assumptions A1/A2/A3 — whether the built images boot against
# an empty postgres, on which port, and whether cx43 is enough — before any DAST code is
# written against a guess. Delete once the answers are recorded in the spec.
on:
  workflow_dispatch:
    inputs:
      image:
        description: "Full GHCR image reference to boot"
        required: true
      port:
        description: "Port the app is expected to listen on"
        required: false
        default: "3000"
      health_path:
        description: "Path to probe"
        required: false
        default: "/"
      needs_db:
        description: "Bring up postgres and redis"
        required: false
        default: "true"

jobs:
  probe:
    runs-on: self-hosted
    permissions:
      contents: read
    env:
      DATABASE_HOST: 127.0.0.1
      DATABASE_PORT: "5432"
      DATABASE_USERNAME: postgres
      DATABASE_PASSWORD: password
      DATABASE_NAME: db_name
    steps:
      - name: Install Docker
        uses: novaitdevteam/nova.ci/.github/actions/install-docker@main

      - name: Login to GitHub Container Registry
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      # Mirrors ci-build-ntk-on-push-tags-run-test.yaml:173-193 so the probe measures the
      # same stack DAST would use, not a different one.
      - name: Start postgres and redis
        if: ${{ inputs.needs_db == 'true' }}
        run: |
          set -euo pipefail
          docker rm -f nova-pg nova-redis >/dev/null 2>&1 || true
          docker run -d --name nova-pg -p 5432:5432 \
            -e POSTGRES_PASSWORD="$DATABASE_PASSWORD" \
            -e POSTGRES_USER="$DATABASE_USERNAME" \
            -e POSTGRES_DB="$DATABASE_NAME" \
            postgres:17.9-trixie
          docker run -d --name nova-redis -p 6379:6379 redis:8
          for i in $(seq 1 60); do
            docker exec nova-pg pg_isready -U "$DATABASE_USERNAME" >/dev/null 2>&1 && break
            sleep 2
          done
          docker exec -e PGPASSWORD="$DATABASE_PASSWORD" nova-pg \
            psql -h 127.0.0.1 -U "$DATABASE_USERNAME" -d "$DATABASE_NAME" \
            -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

      - name: Boot the image and report what happens
        env:
          IMAGE: ${{ inputs.image }}
          PORT: ${{ inputs.port }}
          HEALTH_PATH: ${{ inputs.health_path }}
        run: |
          set -uo pipefail
          docker pull --platform linux/amd64 "$IMAGE"
          docker run -d --name nova-app --network host \
            -e DATABASE_HOST=127.0.0.1 -e DATABASE_PORT=5432 \
            -e DATABASE_USERNAME="$DATABASE_USERNAME" \
            -e DATABASE_PASSWORD="$DATABASE_PASSWORD" \
            -e DATABASE_NAME="$DATABASE_NAME" \
            -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6379 \
            "$IMAGE"

          ok=no
          for i in $(seq 1 90); do
            code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}${HEALTH_PATH}" || true)
            if [ -n "$code" ] && [ "$code" != "000" ]; then
              echo "responded after $((i * 2))s with HTTP $code"; ok=yes; break
            fi
            sleep 2
          done

          {
            echo "## DAST boot probe"
            echo ""
            echo "- Image: \`${IMAGE}\`"
            echo "- Target: \`http://127.0.0.1:${PORT}${HEALTH_PATH}\`"
            echo "- Responded: **${ok}**"
            echo ""
            echo '### Listening ports inside the container'
            echo '```'
            docker exec nova-app sh -c 'netstat -tlnp 2>/dev/null || ss -tlnp 2>/dev/null' || echo "(no netstat/ss in image)"
            echo '```'
            echo '### Last 80 log lines'
            echo '```'
            docker logs --tail 80 nova-app 2>&1
            echo '```'
          } >> "$GITHUB_STEP_SUMMARY"

      - name: Report memory headroom
        if: always()
        run: |
          free -m || true
          docker stats --no-stream || true

      - name: Cleanup
        if: always()
        run: docker rm -f nova-app nova-pg nova-redis >/dev/null 2>&1 || true
```

- [ ] **Step 2: Commit the probe so it can be dispatched**

```bash
./scripts/validate.sh
git add .github/workflows/ci-dast-boot-probe.yaml
git commit -m "Add a temporary DAST boot probe"
git push -u origin feat/sast-dast-scanning
```

- [ ] **Step 3: Run it against both images**

Take the most recent trunk image tags from the notifier messages or from GHCR, then:

```bash
gh workflow run ci-dast-boot-probe.yaml --ref feat/sast-dast-scanning \
  -f image=ghcr.io/novaitdevteam/novatalks.ui:<latest-development-tag> \
  -f port=80 -f health_path=/ -f needs_db=false

gh workflow run ci-dast-boot-probe.yaml --ref feat/sast-dast-scanning \
  -f image=ghcr.io/novaitdevteam/novatalks.core:<latest-development-tag> \
  -f port=3000 -f health_path=/ -f needs_db=true
```

If `novatalks.ui` does not answer on 80, re-run with 8080 and 3000 before concluding anything — the summary's listening-ports block tells you which to try.

- [ ] **Step 4: Record the answers in the spec**

Replace the `How it is settled, and the fallback` cells for A1, A2 and A3 with the measured result: responded yes/no, the working port and health path, seconds to first response, and peak memory. If `novatalks.core` did **not** boot, write that down plainly and note that Tasks 5-7 ship `novatalks.ui` only, with `core` reaching the loud-skip path by design.

- [ ] **Step 5: Delete the probe and commit**

```bash
git rm .github/workflows/ci-dast-boot-probe.yaml
./scripts/validate.sh
git add docs/superpowers/specs/2026-08-28-sast-dast-scanning.md
git commit
```

Message: `Settle the DAST boot assumptions and drop the probe`. Body carries the measured numbers — they are the justification for the port, timeout and runner-size choices in the next two tasks.

---

### Task 5: DAST action, scan.sh and harness

**Files:**
- Create: `.github/actions/dast/action.yml`
- Create: `.github/actions/dast/scan.sh`
- Create: `scripts/test-dast-scan.sh`
- Modify: `scripts/validate.sh` — register the harness, extend the guard to ZAP

**Interfaces:**
- Consumes: measured port, health path and boot timeout from Task 4.
- Produces: `scan.sh` reads env `DAST_IMAGE`, `DAST_PORT`, `DAST_HEALTH_PATH`, `DAST_BOOT_TIMEOUT`, `DAST_NEEDS_DB`, `DAST_PG_IMAGE`, `ZAP_IMAGE`, `DAST_REPORT_FILE`, `REPORT_URL`, and writes `outcome` (`clean|findings|not-run|error`), `findings`, `message`. Task 6 reads exactly these.

- [ ] **Step 1: Write the failing harness**

`scripts/test-dast-scan.sh`:

```bash
#!/usr/bin/env bash
#
# Self-check for .github/actions/dast/scan.sh.
#
# The four outcomes must never collapse into each other: findings, clean, "the app
# never came up" and "ZAP itself broke" mean four different things to whoever reads the
# notification. `docker` is stubbed on PATH, so this runs offline and deterministically
# — ZAP itself is not under test, our decision logic is.
#
# Usage: ./scripts/test-dast-scan.sh
# Exit status: 0 all scenarios passed, 1 a scenario failed.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$ROOT/.github/actions/dast/scan.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

pass=0
fail=0

# docker shim. Records every invocation so cleanup can be asserted, and dispatches on
# the subcommand so "run the app" and "run ZAP" can fail independently.
cat > "$WORK/bin/docker" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "${SHIM_LOG:?}"
case "$1" in
    run)
        case "$*" in
            *zaproxy*)
                printf '%s' "${SHIM_ZAP_REPORT:-WARN-NEW: nothing}" > "${SHIM_ZAP_OUT:?}"
                exit "${SHIM_ZAP_RC:-0}" ;;
            *) exit "${SHIM_APP_RC:-0}" ;;
        esac ;;
    rm|exec|pull|logs) exit 0 ;;
    *) exit 0 ;;
esac
SHIM
chmod +x "$WORK/bin/docker"

# curl shim: the wait-loop's only oracle. SHIM_CURL_RC=0 means the app answered.
cat > "$WORK/bin/curl" <<'SHIM'
#!/usr/bin/env bash
[ "${SHIM_CURL_RC:-0}" = "0" ] && { printf '200'; exit 0; }
printf '000'; exit 7
SHIM
chmod +x "$WORK/bin/curl"

printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/sleep"   # no real waiting
chmod +x "$WORK/bin/sleep"

expect() { # expect <name> <expected-outcome> <expected-exit-code>
    local name="$1" want_outcome="$2" want_rc="$3"
    local out="$WORK/output" summary="$WORK/summary"
    : >"$out"; : >"$summary"; : >"$WORK/log"; : >"$WORK/dockerlog"

    set +e
    PATH="$WORK/bin:$PATH" \
    SHIM_LOG="$WORK/dockerlog" SHIM_ZAP_OUT="$WORK/zap.md" \
    DAST_IMAGE="ghcr.io/x/y:z" \
    DAST_PORT="3000" \
    DAST_HEALTH_PATH="/" \
    DAST_BOOT_TIMEOUT="6" \
    DAST_NEEDS_DB="true" \
    DAST_PG_IMAGE="postgres:16" \
    ZAP_IMAGE="ghcr.io/zaproxy/zaproxy@sha256:deadbeef" \
    DAST_REPORT_FILE="$WORK/report" \
    RUNNER_TEMP="$WORK" \
    REPORT_URL="https://example.invalid/r" \
    GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$summary" \
        bash "$SCAN" >"$WORK/log" 2>&1
    local rc=$?
    set -e

    local got
    got=$(sed -n 's/^outcome=//p' "$out")
    if [ "$got" = "$want_outcome" ] && [ "$rc" = "$want_rc" ]; then
        echo "ok   $name"; pass=$((pass + 1))
    else
        echo "FAIL $name"
        echo "     expected: outcome=$want_outcome rc=$want_rc"
        echo "     actual:   outcome=$got rc=$rc"
        sed 's/^/     /' "$WORK/log"
        fail=$((fail + 1))
    fi
}

assert_cleanup() { # assert_cleanup <name>
    if grep -q 'rm -f nova-app' "$WORK/dockerlog"; then
        echo "ok   $1"; pass=$((pass + 1))
    else
        echo "FAIL $1 — containers were not torn down"; fail=$((fail + 1))
    fi
}

echo "=== dast scan.sh — $SCAN ==="

SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_REPORT="PASS: everything" \
    expect "app boots, ZAP finds nothing" clean 0
assert_cleanup "clean run tears containers down"

SHIM_CURL_RC=0 SHIM_ZAP_RC=2 SHIM_ZAP_REPORT="WARN-NEW: 3 things
WARN-NEW: x
WARN-NEW: y" \
    expect "ZAP warnings are findings, not failure" findings 0
assert_cleanup "findings run tears containers down"

SHIM_CURL_RC=7 \
    expect "app never answers — loud skip, build stays green" not-run 0
assert_cleanup "failed boot still tears containers down"

SHIM_CURL_RC=0 SHIM_ZAP_RC=3 \
    expect "ZAP itself failing to run is an error" error 2
assert_cleanup "errored run still tears containers down"

SHIM_CURL_RC=0 SHIM_APP_RC=1 \
    expect "the app container refusing to start is a loud skip" not-run 0

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run the harness and confirm it fails**

Run: `./scripts/test-dast-scan.sh`
Expected: FAIL — `scan.sh` does not exist.

- [ ] **Step 3: Write `scan.sh`**

```bash
#!/usr/bin/env bash
#
# Bring up the built image with its dependencies, run an OWASP ZAP baseline against it,
# tear everything down, and report one of four outcomes.
#
# The four are deliberately distinct. `clean` and `not-run` in particular must never
# collapse: an application that failed to boot produces exactly the same empty ZAP
# report as a perfectly clean one, and reporting that as clean is the failure this
# whole job exists to avoid. A failed boot is a loud skip with the build left green —
# it comes from .env drift or a missing migration, not from a vulnerability. ZAP itself
# failing is different again, and reds the job.
#
set -euo pipefail

: "${DAST_IMAGE:?}" "${DAST_PORT:?}" "${DAST_HEALTH_PATH:?}" "${DAST_BOOT_TIMEOUT:?}"
: "${ZAP_IMAGE:?}" "${DAST_REPORT_FILE:?}"

DAST_NEEDS_DB="${DAST_NEEDS_DB:-false}"
DAST_PG_IMAGE="${DAST_PG_IMAGE:-postgres:16}"
target="http://127.0.0.1:${DAST_PORT}${DAST_HEALTH_PATH}"
zap_out="${RUNNER_TEMP:-/tmp}/zap.md"

emit() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }

emit_message() {
    {
        echo "message<<DAST_EOF"
        printf '%s\n' "$1"
        echo "DAST_EOF"
    } >> "${GITHUB_OUTPUT:-/dev/null}"
}

cleanup() {
    docker rm -f nova-app nova-pg nova-redis >/dev/null 2>&1 || true
}
trap cleanup EXIT

summary() { # summary <alert> <headline>
    {
        echo "## 🕷 DAST (ZAP baseline)"
        echo ""
        echo "> [!$1]"
        echo "> $2"
        echo ""
        echo "- Image: \`${DAST_IMAGE}\`"
        echo "- Target: \`${target}\`"
        echo "- Report: ${REPORT_URL:-not published}"
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

not_run() { # not_run <reason>
    echo "::warning::DAST did not run: $1"
    emit outcome not-run
    emit findings 0
    emit_message "🕷 DAST (ZAP): ⚠️ не виконано — $1"
    summary WARNING "Scan did not run: $1. This is not a clean result."
    { echo "=== DAST: not run ==="; echo "$1"; } > "$DAST_REPORT_FILE"
    exit 0
}

scanner_error() { # scanner_error <reason>
    echo "::error::DAST scanner failed: $1"
    emit outcome error
    emit findings 0
    emit_message "🕷 DAST (ZAP): ❌ сканер впав — $1"
    summary CAUTION "The scanner itself failed: $1. This is a broken gate."
    exit 2
}

if [ "$DAST_NEEDS_DB" = "true" ]; then
    docker rm -f nova-pg nova-redis >/dev/null 2>&1 || true
    docker run -d --name nova-pg -p 5432:5432 \
        -e POSTGRES_PASSWORD="${DATABASE_PASSWORD:-password}" \
        -e POSTGRES_USER="${DATABASE_USERNAME:-postgres}" \
        -e POSTGRES_DB="${DATABASE_NAME:-db_name}" \
        "$DAST_PG_IMAGE" || not_run "postgres did not start"
    docker run -d --name nova-redis -p 6379:6379 redis:8 || not_run "redis did not start"
    for _ in $(seq 1 30); do
        docker exec nova-pg pg_isready -U "${DATABASE_USERNAME:-postgres}" >/dev/null 2>&1 && break
        sleep 2
    done
    docker exec -e PGPASSWORD="${DATABASE_PASSWORD:-password}" nova-pg \
        psql -h 127.0.0.1 -U "${DATABASE_USERNAME:-postgres}" -d "${DATABASE_NAME:-db_name}" \
        -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;" >/dev/null 2>&1 || true
fi

docker rm -f nova-app >/dev/null 2>&1 || true
docker run -d --name nova-app --network host \
    -e DATABASE_HOST=127.0.0.1 -e DATABASE_PORT=5432 \
    -e DATABASE_USERNAME="${DATABASE_USERNAME:-postgres}" \
    -e DATABASE_PASSWORD="${DATABASE_PASSWORD:-password}" \
    -e DATABASE_NAME="${DATABASE_NAME:-db_name}" \
    -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6379 \
    "$DAST_IMAGE" || not_run "the application container refused to start"

booted=no
attempts=$(( DAST_BOOT_TIMEOUT / 2 ))
[ "$attempts" -ge 1 ] || attempts=1
for _ in $(seq 1 "$attempts"); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "$target" || true)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then booted=yes; break; fi
    sleep 2
done

if [ "$booted" != "yes" ]; then
    docker logs --tail 40 nova-app 2>&1 | sed 's/^/    /' || true
    not_run "образ не піднявся за ${DAST_BOOT_TIMEOUT} с"
fi

set +e
docker run --rm --network host -v "$(dirname "$zap_out"):/zap/wrk:rw" \
    "$ZAP_IMAGE" zap-baseline.py -t "http://127.0.0.1:${DAST_PORT}" \
    -I -w "$(basename "$zap_out")"
zap_rc=$?
set -e

# zap-baseline.py: 0 = nothing, 2 = warnings present (with -I it never returns 1),
# anything else means ZAP could not do its job.
case "$zap_rc" in
    0|2) : ;;
    *)   scanner_error "zap-baseline.py exited ${zap_rc}" ;;
esac

[ -s "$zap_out" ] || scanner_error "ZAP produced no report"

findings=$(grep -c 'WARN-NEW' "$zap_out" || true)
findings="${findings:-0}"

{
    echo "=============================="
    echo " DAST: OWASP ZAP baseline"
    echo " Image:  ${DAST_IMAGE}"
    echo " Target: ${target}"
    echo "=============================="
    echo ""
    cat "$zap_out"
} > "$DAST_REPORT_FILE"

if [ "$findings" -gt 0 ]; then
    echo "::warning::ZAP baseline reported ${findings} warning(s). See ${DAST_REPORT_FILE}."
    emit outcome findings
    emit findings "$findings"
    emit_message "🕷 DAST (ZAP): 🟡 ${findings} warnings"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    summary WARNING "⚠️ ${findings} baseline warning(s) — review the report."
else
    emit outcome clean
    emit findings 0
    emit_message "🕷 DAST (ZAP): 🟢 clean"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    summary NOTE "✅ No baseline warnings."
fi

echo "ZAP baseline — warnings: ${findings}"
```

- [ ] **Step 4: Run the harness and confirm it passes**

Run: `chmod +x .github/actions/dast/scan.sh scripts/test-dast-scan.sh && ./scripts/test-dast-scan.sh`
Expected: `9 passed, 0 failed`.

- [ ] **Step 5: Write `action.yml` with a pinned ZAP image**

```yaml
name: "OWASP ZAP baseline DAST scan"
description: "Boot the built image with its dependencies and run an OWASP ZAP baseline scan against it"

inputs:
  image:
    description: "Full image reference to boot and scan"
    required: true
  port:
    description: "Port the application listens on"
    required: true
  health-path:
    description: "Path polled to decide the application is up"
    required: false
    default: "/"
  boot-timeout:
    description: "Seconds to wait for the first HTTP response before giving up"
    required: false
    default: "180"
  needs-db:
    description: "Bring up postgres and redis alongside the application"
    required: false
    default: "false"
  pg-image:
    description: "Postgres image, when needs-db is true"
    required: false
    default: "postgres:16"
  report-file:
    description: "Path the .report is written to"
    required: true
  report-url:
    description: "Public URL the report will be published at, for the notifier line"
    required: false
    default: ""

outputs:
  outcome:
    description: "clean | findings | not-run | error — a failed boot is not a clean scan"
    value: ${{ steps.scan.outputs.outcome }}
  findings:
    description: "Number of ZAP baseline warnings"
    value: ${{ steps.scan.outputs.findings }}
  message:
    description: "Ready-to-send notifier text"
    value: ${{ steps.scan.outputs.message }}

runs:
  using: composite
  steps:
    # Pinned by digest for the same reason Gitleaks and Semgrep are.
    # To upgrade: docker buildx imagetools inspect ghcr.io/zaproxy/zaproxy:stable
    - name: Boot and scan
      id: scan
      shell: bash
      env:
        DAST_IMAGE: ${{ inputs.image }}
        DAST_PORT: ${{ inputs.port }}
        DAST_HEALTH_PATH: ${{ inputs.health-path }}
        DAST_BOOT_TIMEOUT: ${{ inputs.boot-timeout }}
        DAST_NEEDS_DB: ${{ inputs.needs-db }}
        DAST_PG_IMAGE: ${{ inputs.pg-image }}
        ZAP_IMAGE: "ghcr.io/zaproxy/zaproxy:stable@sha256:REPLACE_WITH_DIGEST_FROM_STEP_6"
        DAST_REPORT_FILE: ${{ inputs.report-file }}
        REPORT_URL: ${{ inputs.report-url }}
        DAST_ACTION_ROOT: ${{ github.action_path }}
      run: |
        set -euo pipefail
        bash "${DAST_ACTION_ROOT}/scan.sh"
```

- [ ] **Step 6: Resolve and substitute the real digest**

```bash
docker buildx imagetools inspect ghcr.io/zaproxy/zaproxy:stable --format '{{.Manifest.Digest}}'
grep -n 'zaproxy' .github/actions/dast/action.yml
```

Expected: one line carrying both `:stable` and `@sha256:`.

- [ ] **Step 7: Register the harness and extend the guard in `validate.sh`**

Add this after the SAST self-check section:

```bash
section "DAST scan self-check"
# The four DAST outcomes must stay distinct: a build that could not boot its own image
# is not a clean scan. The harness stubs docker and curl, so no image is pulled.
if command -v jq >/dev/null 2>&1; then
  if out="$(./scripts/test-dast-scan.sh 2>&1)"; then
    printf '%s\n' "$out" | tail -1
    echo "OK: all dast scan.sh scenarios passed"
  else
    printf '%s\n' "$out"
    echo "ERROR: dast scan.sh self-check failed"
    fail=1
  fi
else
  echo "skip: jq not installed"
fi
```

In the `Scanner invocation` section add:

```bash
zap_offenders="$(grep -nE 'zap-baseline\.py|zap-full-scan\.py|uses:.*zaproxy' .github/workflows/*.yaml \
  | grep -v ':[0-9]*: *#' || true)"
if [ -z "$zap_offenders" ]; then
  echo "OK: no workflow runs ZAP directly"
else
  printf '%s\n' "$zap_offenders" | sed 's/^/       /'
  echo "ERROR: these lines invoke ZAP directly; use .github/actions/dast"
  fail=1
fi
```

- [ ] **Step 8: Validate and commit**

```bash
./scripts/validate.sh
git add .github/actions/dast scripts/test-dast-scan.sh scripts/validate.sh
git commit
```

Message: `Add ZAP baseline DAST behind a composite action`. Body explains why a failed boot is a loud skip rather than a red build, and why ZAP failing is not.

---

### Task 6: Runner sizing for the DAST stack

**Files:**
- Modify: `.github/workflows/ci-build-create-runner.sh:12-42`
- Modify: `scripts/test-create-runner.sh` — the `check` helper and three new scenarios

**Interfaces:**
- Consumes: the memory measurement from Task 4 Step 4 (spec A3).
- Produces: a `check` helper taking an optional fifth `base-ref` argument; four new scenarios, for 20 total. Nothing later depends on it.

- [ ] **Step 1: Extend the harness `check` helper to supply an event payload**

`ci-build-create-runner.sh` will read `base_ref` from `$GITHUB_EVENT_PATH`, so the harness must be able to set it. Change the helper's signature to accept an optional fourth argument:

```bash
check() { # check <name> <ref> <repo> <expected-output-lines> [base-ref]
    local name="$1" ref="$2" repo="$3" expected="$4" base_ref="${5:-}"
    local out summary actual event
    out="$WORK/output" summary="$WORK/summary" event="$WORK/event.json"
    : >"$out"; : >"$summary"
    if [ -n "$base_ref" ]; then
        jq -nc --arg b "$base_ref" '{base_ref: $b}' > "$event"
    else
        echo '{}' > "$event"
    fi

    if ! PATH="$WORK/bin:$PATH" \
        GITHUB_REPOSITORY="novaitdevteam/$repo" GITHUB_REF="$ref" \
        GITHUB_EVENT_PATH="$event" \
        ORG=novaitdevteam GH_TOKEN=t HCLOUD_TOKEN=t \
        GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$summary" \
        bash "$SCRIPT" >"$WORK/log" 2>&1
    then
```

The rest of the function body is unchanged. Existing scenarios pass no fifth argument and therefore get `{}`, which must keep resolving exactly as before.

- [ ] **Step 2: Add the four new scenarios**

Append after the existing scenarios:

```bash
SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
check "core trunk build gets medium: DAST brings up pg, redis and the app" \
    refs/tags/build-NC2-1 novatalks.core \
    'runner_size=cx43
runner_name=<generated>
runner_labels=medium
runner_need=true' \
    refs/heads/development

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
check "core feature-branch build stays small: no DAST, no medium-pool contention" \
    refs/tags/build-NC2-1 novatalks.core \
    'runner_size=cx33
runner_name=<generated>
runner_labels=small
runner_need=true' \
    refs/heads/NC2-123-some-feature

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
check "core scan tag gets medium on any branch: a scan tag always runs DAST" \
    refs/tags/scan-NC2-1 novatalks.core \
    'runner_size=cx43
runner_name=<generated>
runner_labels=medium
runner_need=true' \
    refs/heads/NC2-123-some-feature

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
check "ui trunk build stays small: static assets need no database" \
    refs/tags/build-NC2-1 novatalks.ui \
    'runner_size=cx33
runner_name=<generated>
runner_labels=small
runner_need=true' \
    refs/heads/development
```

- [ ] **Step 3: Run the harness and confirm exactly the two medium scenarios fail**

Run: `./scripts/test-create-runner.sh`
Expected: 18 passed, 2 failed. The 16 existing scenarios still pass (they supply no
`base_ref`, so they must be unaffected), and so do the two new ones that expect `small`
— `core` on a feature branch and `ui` on trunk. The two expecting `cx43`/`medium` FAIL
with `runner_size=cx33`/`runner_labels=small`. Any other pattern means Step 1 changed
existing behaviour and must be fixed before implementing.

- [ ] **Step 4: Implement the sizing branch**

In `ci-build-create-runner.sh`, after the `TAG` block (line 16), add:

```bash
# Tag pushes carry no branch in GITHUB_REF, but the event payload does — and the build
# workflow already derives SHORT_REF_NAME from the same field, so sizing and scanning
# agree by construction. Read here rather than taken as an input, because a new input
# would mean editing every product-repository caller.
BASE_REF="$(jq -r '.base_ref // empty' "${GITHUB_EVENT_PATH:-/dev/null}" 2>/dev/null || true)"
BASE_BRANCH="${BASE_REF#refs/heads/}"
```

Replace the `novatalks.core` branch of the sizing matrix with:

```bash
if [[ "$REPO" == "novatalks.core" ]]; then
    if [[ "$TAG" == scan* ]]; then
        # A scan tag runs DAST on any branch, and DAST means postgres + redis + the
        # app + ZAP on one VM — the same load int-test gets large for.
        REQUIRED_SIZE="medium"
    elif [[ "$TAG" == *build* ]]; then
        case "$BASE_BRANCH" in
            # Trunk builds run DAST; feature builds do not, and must stay out of the
            # medium pool so they never contend with unit-test runs.
            main|master|development) REQUIRED_SIZE="medium" ;;
            *)                       REQUIRED_SIZE="small" ;;
        esac
    elif [[ "$TAG" == *unit-test* ]]; then
        REQUIRED_SIZE="medium"
    elif [[ "$TAG" == *test* ]]; then
        REQUIRED_SIZE="large"
    else
        REQUIRED_SIZE="small"
    fi
else
    REQUIRED_SIZE="small"
fi
```

Update the comment above the matrix so it describes what the code now does, including the DAST reason.

- [ ] **Step 5: Run the harness and confirm all 20 scenarios pass**

Run: `./scripts/test-create-runner.sh`
Expected: `20 passed, 0 failed` — the 16 originals unchanged plus the four new ones.

- [ ] **Step 6: Validate and commit**

```bash
./scripts/validate.sh
git add .github/workflows/ci-build-create-runner.sh scripts/test-create-runner.sh
git commit
```

Message: `Size novatalks.core trunk builds for the DAST stack`. Body cites the memory numbers measured in Task 4.

---

### Task 7: Wire the dast-scan job and its notifier line

**Files:**
- Modify: `.github/workflows/ci-build-ntk-on-push-tags-build.yaml` — new job after `sast-scan`, `notify-telegram`

**Interfaces:**
- Consumes: the action from Task 5, `IS_TRUNK` from Task 2, the measured port/health/timeout from Task 4.
- Produces: job `dast-scan` with outputs `SCANNED`, `OUTCOME`, `FINDINGS`, `MESSAGE`.

- [ ] **Step 1: Add the `dast-scan` job**

```yaml
  dast-scan:
    name: DAST Scan
    runs-on: ${{ inputs.runner_labels  || 'self-hosted' }}
    environment: ${{ inputs.environment }}
    permissions:
      contents: write
    # Same gate as SAST, narrowed to the two repositories whose images are known to boot
    # in CI (spec D4). Everything else reaches DAST only by explicit request.
    if: >-
      ${{ always()
      && github.event_name != 'pull_request'
      && needs.build-image.result == 'success'
      && (needs.build-image.outputs.IS_TRUNK == 'true' || startsWith(github.ref_name, 'scan'))
      && contains(fromJSON('["novatalks.ui","novatalks.core"]'), github.event.repository.name) }}
    needs: [build-image, sast-scan]
    outputs:
      SCANNED: 'true'
      OUTCOME: ${{ steps.dast.outputs.outcome }}
      FINDINGS: ${{ steps.dast.outputs.findings }}
      MESSAGE: ${{ steps.dast.outputs.message }}
    env:
      DAST_TARGET_IMAGE: ghcr.io/${{ github.repository_owner }}/${{ needs.build-image.outputs.REP_NAME }}:${{ needs.build-image.outputs.RELEASE }}_${{ needs.build-image.outputs.SHORT_REF_NAME }}${{ needs.build-image.outputs.IMAGE_SUFFIX }}_${{ needs.build-image.outputs.SHORT_SHA }}
      REPORT_FILE: zap-${{ needs.build-image.outputs.REP_NAME }}-${{ needs.build-image.outputs.SHORT_REF_NAME }}${{ needs.build-image.outputs.IMAGE_SUFFIX }}-${{ needs.build-image.outputs.SHORT_SHA }}.report
      RELEASE_TAG: TRIVY.SCAN_${{ needs.build-image.outputs.RELEASE }}_${{ needs.build-image.outputs.SHORT_REF_NAME }}${{ needs.build-image.outputs.IMAGE_SUFFIX }}_${{ needs.build-image.outputs.SHORT_SHA }}
    steps:
      - name: Install Docker
        uses: novaitdevteam/nova.ci/.github/actions/install-docker@main

      - name: Login to GitHub Container Registry
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Pull built image
        run: docker pull --platform linux/amd64 "$DAST_TARGET_IMAGE"

      - name: ZAP baseline
        id: dast
        uses: novaitdevteam/nova.ci/.github/actions/dast@main
        with:
          image: ${{ env.DAST_TARGET_IMAGE }}
          # Values measured by the Task 4 boot probe. Replace both with the recorded
          # numbers; do not leave the action defaults in place.
          port: ${{ github.event.repository.name == 'novatalks.ui' && 'PROBE_UI_PORT' || 'PROBE_CORE_PORT' }}
          health-path: ${{ github.event.repository.name == 'novatalks.ui' && 'PROBE_UI_PATH' || 'PROBE_CORE_PATH' }}
          boot-timeout: 'PROBE_BOOT_TIMEOUT'
          needs-db: ${{ github.event.repository.name == 'novatalks.core' }}
          pg-image: postgres:17.9-trixie
          report-file: ${{ env.REPORT_FILE }}
          report-url: ${{ github.server_url }}/${{ github.repository }}/releases/download/${{ env.RELEASE_TAG }}/${{ env.REPORT_FILE }}

      - name: Upload report artifact
        if: ${{ always() && hashFiles(env.REPORT_FILE) != '' }}
        uses: actions/upload-artifact@v4
        with:
          name: ${{ env.REPORT_FILE }}
          path: ${{ env.REPORT_FILE }}

      - name: Publish report release
        if: ${{ always() && hashFiles(env.REPORT_FILE) != '' }}
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ env.RELEASE_TAG }}
          name: ${{ env.RELEASE_TAG }}
          prerelease: true
          files: ${{ env.REPORT_FILE }}
```

- [ ] **Step 2: Substitute the probe-measured values**

Replace `PROBE_UI_PORT`, `PROBE_UI_PATH`, `PROBE_CORE_PORT`, `PROBE_CORE_PATH` and `PROBE_BOOT_TIMEOUT` with the numbers recorded in the spec by Task 4. Set `boot-timeout` to roughly twice the slowest observed boot, rounded up to a whole number of seconds. Then confirm none survived:

```bash
grep -n 'PROBE_' .github/workflows/ci-build-ntk-on-push-tags-build.yaml
```

Expected: no output.

- [ ] **Step 3: Add the notifier line**

Extend `notify-telegram`'s `needs` to `[build-image, linter, trivy-scan, unit-test, sast-scan, dast-scan]`, then add after the `Compose SAST line` step:

```yaml
      - name: Compose DAST line
        id: dast_line
        env:
          RESULT: ${{ needs.dast-scan.result }}
          SCANNED: ${{ needs.dast-scan.outputs.SCANNED }}
          MESSAGE: ${{ needs.dast-scan.outputs.MESSAGE }}
        run: |
          set -euo pipefail

          # Four states reach here and none of them may be silent: not scanned at all,
          # scanned with a verdict scan.sh already worded, or a job that died before
          # scan.sh could word anything.
          if [[ "$SCANNED" != "true" ]]; then
            line="🕷 DAST (ZAP): ⏭️ skipped (not enabled for this repository)"
          elif [[ -n "$MESSAGE" ]]; then
            line="$MESSAGE"
          else
            line="🕷 DAST (ZAP): ❌ scan job failed before reporting (${RESULT})"
          fi

          {
            echo "value<<EOF"
            printf '%s\n' "$line"
            echo "EOF"
          } >> "$GITHUB_OUTPUT"
```

Then place `${{ steps.dast_line.outputs.value }}` in the `if_true` message body immediately after `${{ steps.sast_line.outputs.value }}`, separated by a blank line.

- [ ] **Step 4: Verify the release carries all three reports**

Spec assumption A5 says `softprops/action-gh-release@v2` appends rather than replaces. Confirm on the first real run:

```bash
gh release view TRIVY.SCAN_<release>_<ref>_<sha> --repo novaitdevteam/novatalks.ui --json assets \
  --jq '.assets[].name'
```

Expected: three names — `trivy-…`, `semgrep-…`, `zap-…`. If only the last survives, fall back to one release per scanner as described in spec D10, and record the change in the spec.

- [ ] **Step 5: Validate and commit**

```bash
./scripts/validate.sh
git add .github/workflows/ci-build-ntk-on-push-tags-build.yaml
git commit
```

Message: `Run a ZAP baseline against the image novatalks.ui and core just built`.

---

### Task 8: Documentation, diagram and invariants

**Files:**
- Create: `docs/sast-dast.md`, `assets/readme/sast-dast.svg`
- Modify: `docs/README.md`, `docs/container-scanning.md`, `docs/runners.md`, `docs/notifications.md`, `docs/validation.md`, `docs/reference.md`, `CLAUDE.md`, `.agents/skills/nova-ci/SKILL.md`, `.claude/skills/nova-ci/SKILL.md`

**Interfaces:**
- Consumes: everything shipped in Tasks 1-7.
- Produces: the documentation contract the next agent reads before touching any of it.

- [ ] **Step 1: Create the diagram**

Use the `beautify-github-readme` skill. House style is mandatory and enforced: `viewBox` 1200 units wide, the `ui-monospace,SFMono-Regular,Menlo,monospace` stack, the existing palette including GitHub's semantic `#3FB950` / `#F85149` / `#E3862B`, and **no `font-size` below 18**. The diagram shows the two scan paths from the built image through to the three reports on one release and the notifier.

Verify by rendering, not by arithmetic — text clipping against a panel edge does not show up in a width calculation, and this exact shortcut cost a rework on `secret-detection.svg`:

```bash
rsvg-convert -w 900 assets/readme/sast-dast.svg -o /tmp/sast-dast-900.png
rsvg-convert -w 360 assets/readme/sast-dast.svg -o /tmp/sast-dast-360.png
```

Open both and confirm no label is clipped or overlapping.

- [ ] **Step 2: Write `docs/sast-dast.md`**

Open with the diagram (`validate.sh` fails without it), then cover, in the voice of the existing pages: what each scanner is and is not, when each runs, the four DAST outcomes and why a failed boot is not a clean scan, where the three reports live, the Semgrep canary guard and why it exists, the two-repository DAST scope, and the runner-size consequence. Close with the `[← prev] · [Docs index](README.md) · [next →]` footer the other pages use, and insert the page into that chain.

- [ ] **Step 3: Update the surrounding pages**

| Page | Edit |
| --- | --- |
| `docs/README.md` | index entry for the new page |
| `docs/container-scanning.md` | the release now carries three reports; the `TRIVY.SCAN_` prefix is historical |
| `docs/runners.md` | new row in the sizing matrix plus the DAST reason; correct the "branch pushes always small" paragraph so it no longer reads as covering trunk build tags |
| `docs/notifications.md` | the two new message blocks, including the not-run wording |
| `docs/validation.md` | the two new harnesses and the renamed scanner-invocation guard |
| `docs/reference.md` | inventory entries for both actions and both harnesses |

- [ ] **Step 4: Add the invariants to `CLAUDE.md`**

Under a new **Code scanning (SAST/DAST)** heading in the Invariants section:

- `warn-only` governs **findings**. A scanner that could not run reds the job. Never collapse the two.
- A DAST application that fails to boot is a **loud skip** — green build, explicit `⚠️ not run` in the report and the notification. Never silence, never red.
- Keep Semgrep pinned by version **and** digest, never `latest`. **Do not remove the canary rule guard**: Semgrep reporting zero findings and Semgrep having loaded zero rules are indistinguishable without it, exactly like `gitleaks git --log-opts` exiting 0 on an unresolvable range.
- Keep the scan scoped by the `IS_TRUNK` output plus the `scan*` trigger. `trivy-scan` keeps its own gate on purpose — see spec D6 before "simplifying" the two into one.
- DAST is scoped to `novatalks.ui` and `novatalks.core`. Other repositories need an explicit request and a boot probe first.
- The `medium` sizing branch for `novatalks.core` exists for the DAST stack, not for faster builds. Narrowing it to feature branches brings back the OOM; widening it to every core build puts builds into the medium pool, where they contend with unit tests.
- Changing either `scan.sh` means adding a scenario to `scripts/test-sast-scan.sh` or `scripts/test-dast-scan.sh` in the same change.
- No workflow may invoke Semgrep or ZAP directly; `validate.sh` fails on it.

Then update the "Start here" table with a row for `docs/sast-dast.md`, and the Validation paragraph with the two new harnesses.

- [ ] **Step 5: Update both SKILL.md mirrors identically**

Add a **SAST and DAST Semantics** section to `.agents/skills/nova-ci/SKILL.md` covering the same ground, then copy it over the mirror verbatim:

```bash
cp .agents/skills/nova-ci/SKILL.md .claude/skills/nova-ci/SKILL.md
```

`validate.sh` fails if the two diverge.

- [ ] **Step 6: Validate and commit**

```bash
./scripts/validate.sh
git add docs assets/readme/sast-dast.svg CLAUDE.md .agents .claude
git commit
```

Message: `Document SAST and DAST scanning and its invariants`.

- [ ] **Step 7: Open the pull request**

```bash
git push -u origin feat/sast-dast-scanning
gh pr create --base main --title "Add SAST and DAST scanning" --body "…"
```

The body summarises the spec's Problem section, links the spec and this plan, lists what each scanner does and does not cover, and states plainly that the unauthenticated ZAP baseline finds header and cookie hygiene rather than logic flaws — so nobody reads the new green check as a pentest.
