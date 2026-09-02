#!/usr/bin/env bash
#
# Self-check for .github/actions/dast-api/scan.sh.
#
# Same four outcomes as the baseline DAST harness, plus one more: this scanner logs in
# first, so "the app never produced a usable session" is its own class of loud skip
# distinct from "the app never booted at all". `docker` and `curl` are stubbed on PATH —
# this proves the decision logic (which precondition maps to which outcome, and that the
# assembled ZAP command is genuinely in safe mode), not ZAP or the seeded application.
#
# Usage: ./scripts/test-dast-api-scan.sh
# Exit status: 0 all scenarios passed, 1 a scenario failed.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$ROOT/.github/actions/dast-api/scan.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

pass=0
fail=0

# A completed api-scan always prints the one tally line the baseline does; only the
# script driving it differs.
ZAP_CLEAN_CONSOLE="PASS: everything
FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 0	WARN-INPROG: 0	INFO: 0	IGNORE: 0	PASS: 40"

# docker shim. Records every invocation so the assembled zap-api-scan.py command line
# can be inspected, and dispatches on the container name / subcommand so postgres,
# redis, the engine and ZAP can each fail independently — the whole point of the
# not-run scenarios below is that they are distinguishable from one another.
cat > "$WORK/bin/docker" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "${SHIM_LOG:?}"
case "$1" in
    run)
        case "$*" in
            *zaproxy*)
                printf '%s\n' "${SHIM_ZAP_MD:-# ZAP Scanning Report}" > "${SHIM_ZAP_OUT:?}"
                printf '%s\n' "${SHIM_ZAP_CONSOLE:-PASS: everything
FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 0	WARN-INPROG: 0	INFO: 0	IGNORE: 0	PASS: 40}"
                exit "${SHIM_ZAP_RC:-0}" ;;
            *"--name nova-pg"*)    exit "${SHIM_PG_RUN_RC:-0}" ;;
            *"--name nova-redis"*) exit "${SHIM_REDIS_RUN_RC:-0}" ;;
            *"--name nova-app"*)   exit "${SHIM_APP_RC:-0}" ;;
            *) exit 0 ;;
        esac ;;
    exec)
        case "$*" in
            *db:setup:prod*) exit "${SHIM_DBSETUP_RC:-0}" ;;
            *"psql -tAq"*)
                printf '%s\n' "${SHIM_TOKEN_SQL_RESULT-}"
                exit 0 ;;
            *) exit 0 ;;
        esac ;;
    rm|pull|logs) exit 0 ;;
    *) exit 0 ;;
esac
SHIM
chmod +x "$WORK/bin/docker"

# curl shim: three distinct oracles behind one binary, dispatched on the URL each real
# call carries — the boot probe (/livez), the login (/auth/sign_in, headers on stdout
# via -D -), and the spec fetch (/api-docs-json, body written to whatever -o names).
# SHIM_JWT unset means "answer with a token" (the common case for every scenario that
# does not care about login); SHIM_JWT set to the empty string means "the login
# succeeded but carried no token" — the one precondition this scanner has that the
# baseline does not.
cat > "$WORK/bin/curl" <<'SHIM'
#!/usr/bin/env bash
default_spec_body='{"paths":{"/foo":{"get":{}},"/bar":{"post":{},"delete":{}}}}'
url="" out="" prev=""
for a in "$@"; do
    case "$a" in http*) url="$a" ;; esac
    [ "$prev" = "-o" ] && out="$a"
    prev="$a"
done
case "$url" in
    *livez*)
        [ "${SHIM_CURL_RC:-0}" = "0" ] && { printf '200'; exit 0; }
        printf '000'; exit 7 ;;
    *auth/sign_in*)
        if [ -z "${SHIM_JWT+x}" ]; then
            jwt="test-jwt-token-123"
        else
            jwt="$SHIM_JWT"
        fi
        printf 'HTTP/1.1 200 OK\r\n'
        [ -n "$jwt" ] && printf 'Authorization: Bearer %s\r\n' "$jwt"
        printf '\r\n'
        exit 0 ;;
    *api-docs-json*)
        printf '%s' "${SHIM_SPEC_BODY:-$default_spec_body}" > "${out:-/dev/null}"
        exit 0 ;;
esac
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
    : >"$WORK/zap-api.md"; : >"$WORK/report"; rm -f "$WORK/zap-api-console.log"

    set +e
    PATH="$WORK/bin:$PATH" \
    SHIM_LOG="$WORK/dockerlog" SHIM_ZAP_OUT="$WORK/zap-api.md" \
    DAST_IMAGE="ghcr.io/x/y:z" \
    DAST_BOOT_TIMEOUT="6" \
    ZAP_IMAGE="ghcr.io/zaproxy/zaproxy@sha256:deadbeef" \
    DAST_ACTION_ROOT="${DAST_ACTION_ROOT:-$ROOT/.github/actions/dast-api}" \
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

assert_findings() { # assert_findings <name> <expected>
    local got
    got=$(sed -n 's/^findings=//p' "$WORK/output")
    if [ "$got" = "$2" ]; then
        echo "ok   $1"; pass=$((pass + 1))
    else
        echo "FAIL $1 — expected findings=$2, got findings=$got"; fail=$((fail + 1))
    fi
}

assert_failures() { # assert_failures <name> <expected>
    local got
    got=$(sed -n 's/^failures=//p' "$WORK/output")
    if [ "$got" = "$2" ]; then
        echo "ok   $1"; pass=$((pass + 1))
    else
        echo "FAIL $1 — expected failures=$2, got failures=$got"; fail=$((fail + 1))
    fi
}

# assert_zap_flag <name> <substring>
# Greps the recorded zap-api-scan.py invocation for a substring. Every scenario that
# reaches ZAP at all assembles the exact same command line regardless of how the tally
# or exit code turns out, so this can run once after any scenario that got that far.
assert_zap_flag() {
    local name="$1" substr="$2"
    if grep -E 'zap-api-scan\.py' "$WORK/dockerlog" | grep -qF -- "$substr"; then
        echo "ok   $name"; pass=$((pass + 1))
    else
        echo "FAIL $name — zap-api-scan.py invocation missing: $substr"
        grep -E 'zap-api-scan' "$WORK/dockerlog" | sed 's/^/     /' || true
        fail=$((fail + 1))
    fi
}

assert_cleanup() { # assert_cleanup <name>
    if grep -qx 'rm -f nova-app nova-pg nova-redis' "$WORK/dockerlog"; then
        echo "ok   $1"; pass=$((pass + 1))
    else
        echo "FAIL $1 — containers were not torn down"; fail=$((fail + 1))
    fi
}

# assert_mask_emitted <name> <value>
# Greps the script's stdout for the ::add-mask:: line — the one thing that keeps a
# token out of the persisted, world-readable step log, whichever auth-mode produced it.
assert_mask_emitted() {
    local name="$1" value="$2"
    if grep -q "::add-mask::${value}" "$WORK/log"; then
        echo "ok   $name"; pass=$((pass + 1))
    else
        echo "FAIL $name — no ::add-mask:: line for: $value"
        sed 's/^/     /' "$WORK/log"
        fail=$((fail + 1))
    fi
}

echo "=== dast-api scan.sh — $SCAN ==="

# --- clean --------------------------------------------------------------------------
SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "full pipeline, ZAP clean" clean 0
assert_findings "clean api-scan counts zero" 0
assert_cleanup "clean run tears containers down"
# The token only ever exists in the docker argv (same visibility as the generated admin
# password) and in ZAP's own echoed config on stdout — never in the report a human reads.
if grep -q 'test-jwt-token-123' "$WORK/report" 2>/dev/null; then
    echo "FAIL the JWT leaked into the .report file"; fail=$((fail + 1))
else
    echo "ok   the .report file never carries the JWT"; pass=$((pass + 1))
fi
# ZAP echoes the replacer rule (token included) to its own stdout, and `tee` sends that
# stdout to the GitHub Actions step log — a file the runner persists the instant it is
# written, unlike the console log copy, which the trap can and does delete. The only
# thing that keeps the token out of that persisted, world-readable (nova.ci is public)
# log is `::add-mask::`, emitted as soon as login confirms a token, before anything else
# ever echoes it.
if grep -q '::add-mask::test-jwt-token-123' "$WORK/log"; then
    echo "ok   the JWT is masked from the step log via ::add-mask::"; pass=$((pass + 1))
else
    echo "FAIL no ::add-mask:: line for the JWT — it would reach the persisted step log"
    sed 's/^/     /' "$WORK/log"
    fail=$((fail + 1))
fi

# --- findings, including must-fix ----------------------------------------------------
# One run, two counts: FAIL-NEW and WARN-NEW are read from the same tally line, and a
# FAIL-level finding does not red the build — warn-only governs findings, not exit code.
SHIM_ZAP_RC=1 SHIM_ZAP_CONSOLE="FAIL-NEW: Some Critical Alert [90001] x 2
WARN-NEW: Some Warning Alert [10038] x 5
FAIL-NEW: 2	FAIL-INPROG: 0	WARN-NEW: 5	WARN-INPROG: 0	INFO: 0	IGNORE: 0	PASS: 30" \
    expect "api-scan warnings are findings, build green" findings 0
assert_findings "warnings counted from the tally" 5
assert_failures "FAIL-NEW counted on its own" 2

# --- not-run: every precondition is a loud skip --------------------------------------
SHIM_PG_RUN_RC=1 expect "postgres down is a loud skip" not-run 0
assert_cleanup "postgres-down run still tears containers down"

SHIM_DBSETUP_RC=1 expect "migration failure is a loud skip" not-run 0
SHIM_DBSETUP_RC=1 expect "seed failure is a loud skip" not-run 0

SHIM_CURL_RC=7 expect "boot timeout is a loud skip" not-run 0

SHIM_JWT="" expect "login returns no JWT is a loud skip" not-run 0

SHIM_SPEC_BODY='{"paths":{}}' \
    expect "empty /api-docs-json is a loud skip" not-run 0

# --- error: the scanner itself is broken ---------------------------------------------
SHIM_ZAP_RC=3 expect "zap-api-scan crash is a scanner error" error 2

SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: everything looked fine" \
    expect "a missing tally is a scanner error" error 2

# --- safe mode: the assembled ZAP command must carry -S -------------------------------
# The one flag whose absence turns a passive scan into real POST/PUT/DELETE against the
# seeded API. Read from the "missing tally" scenario just run above, which still reaches
# ZAP and still assembles the full command line before the tally is ever inspected.
assert_zap_flag "safe mode -S is always passed" '-S'
assert_zap_flag "openapi format is passed" '-f openapi'
# the JWT reaches ZAP as a replacer rule, not the raw token in the report.
assert_zap_flag "auth is injected via a replacer rule" 'replacer.full_list(0).matchstr=Authorization'

# --- the JWT never appears anywhere durable -------------------------------------------
# The token only ever exists in the docker argv (same visibility as the generated
# admin password) and in ZAP's own echoed config on stdout — which is exactly why the
# console log is deleted in the trap and never becomes the .report.
if [ -f "$WORK/zap-api-console.log" ]; then
    echo "FAIL the ZAP console log survived the process — it carries the JWT in the replacer echo"
    fail=$((fail + 1))
else
    echo "ok   the ZAP console log is deleted once the process exits"; pass=$((pass + 1))
fi

# --- db-token mode: a connector's own header, not the engine's login -------------------
# db-token mode: migrate+seed run, the SELECT returns a token, it is injected under the
# configured header (not Authorization), and the scan runs safe-mode.
DAST_AUTH_MODE="db-token" DAST_AUTH_HEADER="api_access_token" DAST_AUTH_PREFIX="" \
DAST_TOKEN_SQL="SELECT token FROM api_tokens ORDER BY id DESC LIMIT 1" \
SHIM_TOKEN_SQL_RESULT="nova-ci-fake-token" \
SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "db-token mode: seed, read token, scan clean" clean 0
assert_zap_flag "the configured auth header is injected" 'replacer.full_list(0).matchstr=api_access_token'
assert_zap_flag "no Bearer prefix when the scheme prefix is empty" 'replacement=nova-ci-fake-token'
assert_mask_emitted "the db-token value is masked" 'nova-ci-fake-token'

# empty token from the SELECT is a loud skip, never a scan without auth
DAST_AUTH_MODE="db-token" DAST_TOKEN_SQL="SELECT token FROM api_tokens ORDER BY id DESC LIMIT 1" \
SHIM_TOKEN_SQL_RESULT="" \
    expect "db-token mode: empty SELECT is a loud skip" not-run 0

# login mode still works unchanged (core), with the default Authorization/Bearer header
SHIM_ZAP_RC=1 SHIM_ZAP_CONSOLE="FAIL-NEW: Some Critical Alert [90001] x 2
WARN-NEW: Some Warning Alert [10038] x 5
FAIL-NEW: 2	FAIL-INPROG: 0	WARN-NEW: 5	WARN-INPROG: 0	INFO: 0	IGNORE: 0	PASS: 30" \
    expect "login mode still injects Authorization: Bearer" findings 0
assert_zap_flag "login mode keeps the Bearer prefix" 'replacement=Bearer '

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
