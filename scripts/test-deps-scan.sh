#!/usr/bin/env bash
#
# Self-check for .github/actions/deps-scan/scan.sh.
#
# scan.sh combines two independent scanners — Trivy fs (JSON read from a file, as if
# written by the caller's own aquasecurity/trivy-action step) and OSV-Scanner (invoked
# here via a stubbed `docker`, on PATH) — into one clean/findings/no-manifests/error
# outcome, and the whole point of this script is to never let either tool's "ran but
# found nothing" collapse into "ran but was never proven to have parsed anything". Every
# decision branch gets a scenario, including the two silent-zero traps verified live
# against the real tools while writing scan.sh:
#   - OSV-Scanner exits non-{0,1,128} while still printing a perfectly well-formed JSON
#     document with packages listed and zero vulnerabilities — a real network failure
#     reproduced with `docker run --network none` looks identical to a clean scan in the
#     JSON body alone.
#   - Trivy's own JSON has no `.Results` key at all when it found no lockfile, and a
#     `.Results[].Packages` count of zero is treated the same way defensively.
#
# Usage: ./scripts/test-deps-scan.sh
# Exit status: 0 all scenarios passed, 1 a scenario failed.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION_DIR="$ROOT/.github/actions/deps-scan"
SCAN="$ACTION_DIR/scan.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/src"

pass=0
fail=0

# docker shim: stands in for the OSV-Scanner invocation only (Trivy is read from a plain
# JSON file, as scan.sh expects — it never shells out to Trivy itself). Writes
# $SHIM_OSV_JSON to stdout (this is what scan.sh redirects into its own osv_json temp
# file) and $SHIM_OSV_ERR to stderr, then exits $SHIM_OSV_RC.
cat > "$WORK/bin/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s' "${SHIM_OSV_JSON:-{\}}"
printf '%s' "${SHIM_OSV_ERR:-}" >&2
exit "${SHIM_OSV_RC:-0}"
SHIM
chmod +x "$WORK/bin/docker"

# Trivy JSON with the given vulnerabilities. no-results:yes omits .Results entirely
# (Trivy's own shape for "no lockfile found"); zero-packages gives a .Results entry with
# an empty .Packages array (defensive case — should not happen live, but the guard must
# still hold if it ever does).
trivy_json() { # trivy_json <shape:normal|no-results|zero-packages> [severity]...
    local shape="$1"; shift
    case "$shape" in
        no-results)
            echo '{"SchemaVersion":2,"ArtifactName":"/src"}'
            return
            ;;
        zero-packages)
            echo '{"Results":[{"Target":"package-lock.json","Class":"lang-pkgs","Type":"npm","Packages":[]}]}'
            return
            ;;
    esac
    local vulns="[]" sev
    for sev in "$@"; do
        vulns=$(jq -c --arg s "$sev" \
            '. + [{"VulnerabilityID":"CVE-x","PkgName":"pkg-a","InstalledVersion":"1.0.0","FixedVersion":"1.0.1","Severity":$s}]' \
            <<<"$vulns")
    done
    jq -c --argjson v "$vulns" \
        '{Results: [{Target: "package-lock.json", Class: "lang-pkgs", Type: "npm", Packages: [{Name:"pkg-a", Version:"1.0.0"}], Vulnerabilities: $v}]}' <<<'{}'
}

# OSV-Scanner JSON (--all-packages shape) with the given number of vulnerabilities on one
# package. no-packages gives results:[] (defensive — real OSV-Scanner reports this shape
# as exit 128 with EMPTY stdout, never as exit 0/1 with an empty package list; covered
# separately below since the exit code, not the JSON, is what really happens).
osv_json() { # osv_json <n-vulns>
    local n="$1"
    local vulns="[]"
    local i
    for ((i = 0; i < n; i++)); do
        vulns=$(jq -c --arg id "GHSA-x$i" \
            '. + [{"id":$id, "database_specific":{"severity":"HIGH"}, "affected":[{"package":{"name":"pkg-b","ecosystem":"npm"},"ranges":[{"events":[{"fixed":"2.0.0"}]}]}]}]' \
            <<<"$vulns")
    done
    jq -c --argjson v "$vulns" \
        '{results: [{source: {path: "/src/package-lock.json", type: "lockfile"}, packages: [{package: {name: "pkg-b", version: "1.0.0", ecosystem: "npm"}, vulnerabilities: $v}]}]}' <<<'{}'
}

run() { # run <trivy-json-content> <trivy-outcome> <shim-osv-json> <shim-osv-rc>
    local tjson="$1" toutcome="$2" ojson="$3" orc="$4"
    local out="$WORK/output" summary="$WORK/summary" report="$WORK/report"
    : >"$out"; : >"$summary"; : >"$report"
    printf '%s' "$tjson" > "$WORK/trivy.json"

    set +e
    PATH="$WORK/bin:$PATH" \
    OSV_IMAGE="ghcr.io/google/osv-scanner@sha256:deadbeef" \
    DEPS_SRC="$WORK/src" \
    DEPS_REPORT_FILE="$report" \
    DEPS_ACTION_ROOT="$ACTION_DIR" \
    REPORT_URL="https://example.invalid/r" \
    TRIVY_JSON="$WORK/trivy.json" \
    TRIVY_OUTCOME="$toutcome" \
    RUNNER_TEMP="$WORK" \
    GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$summary" \
    SHIM_OSV_JSON="$ojson" SHIM_OSV_RC="$orc" \
        bash "$SCAN" >"$WORK/log" 2>&1
    LAST_RC=$?
    set -e
}

# missing-trivy-json: run() above with an explicit sentinel; handled by a separate
# helper since it must NOT write $WORK/trivy.json at all.
run_missing_trivy_file() { # run_missing_trivy_file <trivy-outcome> <shim-osv-json> <shim-osv-rc>
    local toutcome="$1" ojson="$2" orc="$3"
    local out="$WORK/output" summary="$WORK/summary" report="$WORK/report"
    : >"$out"; : >"$summary"; : >"$report"
    rm -f "$WORK/trivy.json"

    set +e
    PATH="$WORK/bin:$PATH" \
    OSV_IMAGE="ghcr.io/google/osv-scanner@sha256:deadbeef" \
    DEPS_SRC="$WORK/src" \
    DEPS_REPORT_FILE="$report" \
    DEPS_ACTION_ROOT="$ACTION_DIR" \
    REPORT_URL="https://example.invalid/r" \
    TRIVY_JSON="$WORK/trivy.json" \
    TRIVY_OUTCOME="$toutcome" \
    RUNNER_TEMP="$WORK" \
    GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$summary" \
    SHIM_OSV_JSON="$ojson" SHIM_OSV_RC="$orc" \
        bash "$SCAN" >"$WORK/log" 2>&1
    LAST_RC=$?
    set -e
}

expect() { # expect <name> <expected-outcome> <expected-findings>
    local name="$1" want_outcome="$2" want_findings="$3"
    local got_outcome got_findings
    got_outcome=$(sed -n 's/^outcome=//p' "$WORK/output")
    got_findings=$(sed -n 's/^findings=//p' "$WORK/output")

    if [ "$got_outcome" = "$want_outcome" ] && [ "$got_findings" = "$want_findings" ]; then
        echo "ok   $name"; pass=$((pass + 1))
    else
        echo "FAIL $name"
        echo "     expected: outcome=$want_outcome findings=$want_findings"
        echo "     actual:   outcome=$got_outcome findings=$got_findings (rc=$LAST_RC)"
        sed 's/^/     /' "$WORK/log"
        fail=$((fail + 1))
    fi
}

expect_rc() { # expect_rc <name> <expected-rc>
    if [ "$LAST_RC" = "$2" ]; then
        echo "ok   $1"; pass=$((pass + 1))
    else
        echo "FAIL $1 — expected rc=$2, got rc=$LAST_RC"; fail=$((fail + 1))
    fi
}

assert_in() { # assert_in <name> <file> <grep-pattern> [--absent]
    local name="$1" file="$2" pat="$3" mode="${4:-}"
    if grep -q "$pat" "$file" 2>/dev/null; then
        [ "$mode" = "--absent" ] && { echo "FAIL $name"; fail=$((fail + 1)); return; }
    else
        [ "$mode" != "--absent" ] && { echo "FAIL $name"; fail=$((fail + 1)); return; }
    fi
    echo "ok   $name"; pass=$((pass + 1))
}

echo "=== deps-scan scan.sh — $SCAN ==="

# --- clean: both tools parsed a real package, neither found a vulnerability ---
run "$(trivy_json normal)" success "$(osv_json 0)" 0
expect "clean: both tools parsed, zero findings" clean 0
expect_rc "clean exits 0" 0

# --- findings: Trivy alone ---
run "$(trivy_json normal HIGH CRITICAL)" success "$(osv_json 0)" 0
expect "Trivy findings alone are counted" findings 2

# --- findings: OSV-Scanner alone (exit 1 = ErrVulnerabilitiesFound) ---
run "$(trivy_json normal)" success "$(osv_json 3)" 1
expect "OSV-Scanner findings alone are counted" findings 3

# --- findings: both tools, added together, never de-duplicated ---
run "$(trivy_json normal HIGH)" success "$(osv_json 2)" 1
expect "findings from both tools add up" findings 3
assert_in "report lists the Trivy section" "$WORK/report" "=== Trivy (fs, vuln): parsed"
assert_in "report lists the OSV-Scanner section" "$WORK/report" "=== OSV-Scanner: parsed"

# --- no manifests found: both tools agree there is nothing to scan ---
# Trivy's real shape for this is no .Results key at all; OSV-Scanner's real shape is
# exit 128 (ErrNoPackagesFound) with completely empty stdout — never a JSON body.
run "$(trivy_json no-results)" success "" 128
expect "no manifests found: both tools agree" no-manifests 0
expect_rc "no-manifests exits 0 (green, loud, never red)" 0
assert_in "summary flags no-manifests, not a clean scan" "$WORK/summary" "No lockfile found by either tool"

# --- mixed: one tool has no manifest signal, the other genuinely parsed something ---
# This must NOT be reported as no-manifests: one engine's coverage gap for this
# ecosystem is not evidence that nothing was scanned.
run "$(trivy_json no-results)" success "$(osv_json 1)" 1
expect "mixed no-manifest/parsed reports the parsing tool's findings" findings 1

run "$(trivy_json normal HIGH)" success "" 128
expect "mixed parsed/no-manifest the other way round" findings 1

# --- defensive: Trivy .Results present but every entry's .Packages is empty ---
run "$(trivy_json zero-packages)" success "" 128
expect "Trivy Results with zero packages is treated as no-manifest, not clean" no-manifests 0

# --- error: the Trivy step itself failed before scan.sh ever ran ---
run "$(trivy_json normal)" failure "$(osv_json 0)" 0
expect "a failed Trivy step is an error, never a clean scan" error 0
expect_rc "Trivy step failure exits 2" 2
assert_in "the reason names Trivy" "$WORK/log" "Trivy:.*outcome was 'failure'"

# --- error: Trivy's JSON file does not exist at all ---
run_missing_trivy_file success "$(osv_json 0)" 0
expect "a missing Trivy output file is an error" error 0
expect_rc "missing Trivy file exits 2" 2

# --- error: Trivy's JSON file is not valid JSON ---
run "not json at all" success "$(osv_json 0)" 0
expect "unparseable Trivy output is an error" error 0

# --- The two silent-zero traps this script exists to close ---

# OSV-Scanner exit 127 (generic error) or 129 (ErrAPIFailed) can still print a
# perfectly well-formed JSON body with packages listed and zero vulnerabilities — a real
# network failure reproduced live while writing scan.sh. Only the exit code tells this
# apart from a genuinely clean scan; the JSON alone does not.
run "$(trivy_json normal)" success "$(osv_json 0)" 127
expect "OSV-Scanner exit 127 with clean-looking JSON is still an error" error 0
expect_rc "exit 127 exits 2" 2

run "$(trivy_json normal)" success "$(osv_json 0)" 129
expect "OSV-Scanner exit 129 (ErrAPIFailed) with clean-looking JSON is still an error" error 0

# --- error: OSV-Scanner exits 0 but prints garbage ---
run "$(trivy_json normal)" success "not json either" 0
expect "unparseable OSV-Scanner output is an error" error 0

# --- error: both tools broken at once still reports error, not one cancelling the other ---
run "not json at all" success "not json either" 0
expect "both tools broken at once is still error" error 0
assert_in "the reason names both tools" "$WORK/log" "Trivy:.*OSV-Scanner:"

# --- report content: package, installed version, fixed version, severity, advisory ID ---
run "$(trivy_json normal HIGH)" success "$(osv_json 1)" 1
expect "report-content scenario" findings 2
assert_in "report names the Trivy package" "$WORK/report" "pkg-a"
assert_in "report names the Trivy installed version" "$WORK/report" "1.0.0"
assert_in "report names the Trivy fixed version" "$WORK/report" "1.0.1"
assert_in "report names the Trivy severity" "$WORK/report" "HIGH"
assert_in "report names the Trivy advisory ID" "$WORK/report" "CVE-x"
assert_in "report names the OSV package" "$WORK/report" "pkg-b"
assert_in "report names the OSV fixed version (cross-referenced from affected[])" "$WORK/report" "2.0.0"
assert_in "report names the OSV advisory ID" "$WORK/report" "GHSA-x0"

# --- summary: findings are listed inline, not only in the artifact ---
assert_in "the summary lists the Trivy finding" "$WORK/summary" "pkg-a"
assert_in "the summary lists the OSV-Scanner finding" "$WORK/summary" "pkg-b"
assert_in "no truncation note below the cap" "$WORK/summary" "Showing 25 of" --absent

# --- summary: a clean scan gets no findings block at all ---
run "$(trivy_json normal)" success "$(osv_json 0)" 0
expect "a clean scan lists nothing" clean 0
assert_in "no findings block on a clean scan" "$WORK/summary" "<details>" --absent

# --- above the cap, the summary truncates and names the artifact ---
many_sevs=()
for i in $(seq 1 30); do many_sevs+=(HIGH); done
run "$(trivy_json normal "${many_sevs[@]}")" success "$(osv_json 0)" 1
expect "30 findings still report as 30" findings 30
assert_in "the summary says how many of how many it showed" "$WORK/summary" "Showing 25 of 30"
assert_in "and names the artifact that has the rest" "$WORK/summary" "artifact"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
