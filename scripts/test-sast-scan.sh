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

assert_warnings() { # assert_warnings <name> <expected>
    local got
    got=$(sed -n 's/^warnings=//p' "$WORK/output")
    if [ "$got" = "$2" ]; then
        echo "ok   $1"; pass=$((pass + 1))
    else
        echo "FAIL $1 — expected warnings=$2, got warnings=$got"; fail=$((fail + 1))
    fi
}

echo "=== semgrep scan.sh — $SCAN ==="

SHIM_JSON="$(semgrep_json yes)" SHIM_RC=0 \
    expect "clean scan reports clean" clean 0

SHIM_JSON="$(semgrep_json yes ERROR ERROR)" SHIM_RC=1 \
    expect "two ERROR findings are counted" findings 2

# WARNING used to be invisible: the old filter was an exact equality on ERROR, and the
# same filter built the report body, so a repository's WARNING findings appeared in
# neither the count nor the published artifact. novatalks.core had 12 nobody ever saw.
SHIM_JSON="$(semgrep_json yes WARNING)" SHIM_RC=1 \
    expect "a lone WARNING is a finding, not a clean scan" findings 0
assert_warnings "the WARNING lands in its own count" 1
assert_report "report lists the WARNING section" "=== WARNING: 1 ==="

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

# The canary is mounted from the action's own directory and carries a hardcoded INFO
# severity. It proves the engine ran and must never be countable as a finding of the
# repository under scan, nor leak into the published report.
SHIM_JSON="$(semgrep_json yes)" SHIM_RC=0 \
    expect "canary alone is a clean scan" clean 0
assert_warnings "canary alone counts no warnings" 0
assert_report "report never contains the canary" "nova-ci-semgrep-canary" --absent

# The real picture: both levels counted, both listed, neither hiding the other.
SHIM_JSON="$(semgrep_json yes ERROR ERROR WARNING WARNING WARNING)" SHIM_RC=1 \
    expect "ERROR and WARNING are counted separately" findings 2
assert_warnings "the three WARNING findings are their own number" 3
assert_report "report lists the ERROR section" "=== ERROR: 2 ==="
assert_report "report lists the WARNING section too" "=== WARNING: 3 ==="

# INFO is counted for the summary but deliberately kept out of the report body: the OSS
# packs emit it liberally and it would bury the two levels that carry a decision.
#
# Written out rather than built by semgrep_json because that helper names every finding
# `rule.x` regardless of severity, and "the report body does not name this rule" is only
# an assertion about INFO if the rule ID belongs to the INFO finding alone. With the
# shared ID the same string could have come from an ERROR or WARNING listing and the
# check would pass no matter what the body contained.
SHIM_JSON='{"results":[{"check_id":"nova-ci-semgrep-canary","extra":{"severity":"INFO"}},{"check_id":"rule.info-only","path":"src/a.ts","start":{"line":3},"extra":{"severity":"INFO","message":"m"}},{"check_id":"rule.info-only","path":"src/b.ts","start":{"line":4},"extra":{"severity":"INFO","message":"m"}}],"errors":[],"paths":{"scanned":["src/a.ts","src/b.ts"]}}' SHIM_RC=1 \
    expect "INFO alone is not a finding" clean 0
assert_warnings "INFO alone counts no warnings" 0
assert_report "the report body does not list INFO findings" "rule.info-only" --absent
if grep -q 'INFO: 2' "$WORK/summary"; then
    echo "ok   INFO findings are still counted in the job summary"; pass=$((pass + 1))
else
    echo "FAIL the job summary does not report the INFO count"; fail=$((fail + 1))
fi

# The zero-files guard sits ahead of the canary guard in scan.sh, so the existing
# empty-.paths.scanned fixture (which has no canary either) was caught by the canary
# guard whenever the zero-files one was removed, and the guard was untestable. A firing
# canary isolates it: everything else about this run says "completed and clean".
SHIM_JSON='{"results":[{"check_id":"nova-ci-semgrep-canary","extra":{"severity":"INFO"}}],"errors":[],"paths":{"scanned":[]}}' SHIM_RC=0 \
    expect "zero files scanned is an error even with a firing canary" error 0

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
