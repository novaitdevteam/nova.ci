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
# SHIM_SKIP_WRITE simulates a container that dies before writing anything —
# e.g. it never got as far as producing output.
if [ -z "${SHIM_SKIP_WRITE:-}" ]; then
    printf '%s' "${SHIM_JSON:-{\}}" > "${SHIM_OUT:?SHIM_OUT unset}"
fi
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
    rm -f "$WORK/semgrep.json"

    set +e
    PATH="$WORK/bin:$PATH" \
    SEMGREP_IMAGE="semgrep/semgrep@sha256:deadbeef" \
    SEMGREP_CONFIGS="p/typescript" \
    SEMGREP_SEVERITY="${SEMGREP_SEVERITY:-ERROR}" \
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
    LAST_RC="$rc"

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

SHIM_SKIP_WRITE=1 SHIM_RC=1 \
    expect "docker writes no output file at all is an error" error 0

SHIM_JSON='{"results":[],"errors":[],"paths":{"scanned":[]}}' SHIM_RC=0 \
    expect "scanning zero files is an error, never a clean run" error 0

SHIM_JSON='not json at all' SHIM_RC=0 \
    expect "unparseable output is an error" error 0

# The canary alone does not prove the rule packs loaded: it is mounted from the action's
# own directory, so it resolves and fires even when every registry --config fails to
# fetch. Semgrep records those failures in .errors[]. Files scanned, canary firing, zero
# findings — the exact shape of a clean run — must still come out `error`.
SHIM_JSON='{"results":[{"check_id":"nova-ci-semgrep-canary","extra":{"severity":"INFO"}}],"errors":[{"code":7,"level":"error","message":"Invalid rule schema / config p/typescript could not be fetched"}],"paths":{"scanned":["src/a.ts"]}}' SHIM_RC=0 \
    expect "a config-resolution error is an error even with a firing canary" error 0
if [ "$LAST_RC" = "2" ]; then
    echo "ok   a config-resolution error (no path) exits 2"; pass=$((pass + 1))
else
    echo "FAIL a config-resolution error exited $LAST_RC, expected 2"; fail=$((fail + 1))
fi
if grep -q 'could not be fetched' "$WORK/log"; then
    echo "ok   the config-resolution error detail is printed"; pass=$((pass + 1))
else
    echo "FAIL the config-resolution error detail is missing from the output"; fail=$((fail + 1))
fi

# novatalks.core regression: 12 errors, all per-file (parse errors, timeouts — every
# one carries a `path`), on a run whose configs are known-good (novatalks.ui ran the
# same three registry packs with the same pinned image 40 minutes earlier: zero errors,
# three findings). Errors that all name a file must not fail the job — the scan
# completes and findings are still counted normally.
SHIM_JSON='{"results":[{"check_id":"nova-ci-semgrep-canary","extra":{"severity":"INFO"}},{"check_id":"rule.x","path":"src/a.ts","start":{"line":3},"extra":{"severity":"ERROR","message":"m"}}],"errors":[{"level":"warn","type":"timeout","path":"src/b.ts","message":"Timeout scanning a large generated file"},{"level":"warn","type":"parse","path":"src/c.ts","message":"Could not parse src/c.ts"}],"paths":{"scanned":["src/a.ts","src/b.ts","src/c.ts"]}}' SHIM_RC=1 \
    expect "errors that all carry a path do not fail the scan" findings 1
if [ "$LAST_RC" = "0" ]; then
    echo "ok   per-file-only errors still exit 0"; pass=$((pass + 1))
else
    echo "FAIL per-file-only errors exited $LAST_RC, expected 0"; fail=$((fail + 1))
fi
if grep -q 'Timeout scanning a large generated file' "$WORK/log" && grep -q 'Could not parse src/c.ts' "$WORK/log"; then
    echo "ok   per-file error detail is printed even though the scan completes"; pass=$((pass + 1))
else
    echo "FAIL per-file error detail is missing from the output"
    sed 's/^/     /' "$WORK/log"
    fail=$((fail + 1))
fi

SHIM_JSON="$(semgrep_json yes ERROR)" SHIM_RC=1 \
    expect "single finding" findings 1
assert_report "report names the rule" "rule.x"
assert_report "report never contains the canary" "nova-ci-semgrep-canary" --absent

# severity is a caller-configurable input with no enum restriction. If it is ever set
# to the canary's own hardcoded INFO severity, the canary hit must still be excluded by
# check_id, never counted as a finding and never leaked into the report.
SEMGREP_SEVERITY=INFO SHIM_JSON="$(semgrep_json yes)" SHIM_RC=0 \
    expect "canary is never a finding even at its own INFO severity" clean 0
assert_report "report never contains the canary at INFO severity" "nova-ci-semgrep-canary" --absent

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
