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
