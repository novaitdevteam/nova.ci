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
                # One element per line, unlike the flattened "$*" log above: the -z
                # value is a single argv element whose internal quoting is exactly what
                # is under test, and "$*" destroys it.
                printf '%s\n' "$@" > "${SHIM_ZAP_ARGV:?}"
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
            *db:setup*) printf '%s\n' "${SHIM_DBSETUP_OUT:-}"; exit "${SHIM_DBSETUP_RC:-0}" ;;
            *pg_isready*) exit "${SHIM_PG_READY_RC:-0}" ;;
            *"INSERT INTO"*)
                # psql quotes the offending statement back on error (ERROR: ... / LINE 1:
                # <the statement>), token and all. That is the whole reason the mask has to
                # precede the INSERT rather than follow it, so the shim reproduces it.
                if [ "${SHIM_INSERT_RC:-0}" != "0" ]; then
                    printf 'ERROR:  relation "tokens" does not exist\nLINE 1: %s\n' "$*"
                fi
                exit "${SHIM_INSERT_RC:-0}" ;;
            *"psql -tAq"*)
                printf '%s\n' "${SHIM_TOKEN_SQL_RESULT-}"
                exit 0 ;;
            *) exit 0 ;;
        esac ;;
    # `docker inspect -f '{{.State.Running}}'` is how scan.sh tells "the image never
    # started" from "the setup command failed" — two causes that used to share one
    # message. SHIM_APP_STATE drives that fork.
    inspect) printf '%s\n' "${SHIM_APP_STATE:-true}"; exit 0 ;;
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
    : >"$WORK/zap-argv"

    set +e
    PATH="$WORK/bin:$PATH" \
    SHIM_LOG="$WORK/dockerlog" SHIM_ZAP_OUT="$WORK/zap-api.md" \
    SHIM_ZAP_ARGV="$WORK/zap-argv" \
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

SHIM_DBSETUP_RC=1 DAST_SETUP_CMD="npm run db:setup:prod" \
    expect "migration failure is a loud skip" not-run 0
SHIM_DBSETUP_RC=1 DAST_SETUP_CMD="npm run db:setup:prod" \
    expect "seed failure is a loud skip" not-run 0

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

# db-token mode with no token-sql is a broken configuration, not a scan: fail loud.
DAST_AUTH_MODE="db-token" DAST_TOKEN_SQL="" expect "db-token without token-sql is a scanner error" error 2

# --- db-insert: write our own row rather than depend on the image's seeder -------------
# whatsapp and signal prune ts-node out of the runtime image, but their entrypoints still
# migrate and seed themselves through the compiled JS in dist/ — a token row very likely
# exists. It is just not one we chose: db-token would have to guess its role value and
# column shape out of a seeder we do not own, and a guess that misses SELECTs nothing.
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
# Matched by the "nova-ci-apiscan-" prefix scan.sh generates it with (Step 3), not by
# position: scan.sh always masks ADMIN_PASS first (unconditionally, every mode, before
# any container exists) and TOKEN second. Grabbing "the first" or "the last" ::add-mask::
# line both pass by accident here — ADMIN_PASS also appears in dockerlog on the nova-app
# `docker run` line, so either position check is satisfied whether or not TOKEN itself
# was ever masked at all. Matching the token's own shape is the only way this assertion
# fails when it should.
mask_line=$(sed -n 's/^::add-mask:://p' "$WORK/log" | grep '^nova-ci-apiscan-' | head -1 || true)
if [ -n "$mask_line" ] && grep -qF "$mask_line" "$WORK/dockerlog"; then
    echo "ok   the generated token is masked and is the one injected"; pass=$((pass + 1))
else
    echo "FAIL the generated token was not masked, or not the one used"; fail=$((fail + 1))
fi

# The mask has to precede the INSERT, not follow it. The token is interpolated into the
# statement and handed to `docker exec`, and the failure path prints psql's own output —
# which quotes the statement back, token included. nova.ci is public, so a mask emitted
# after that point protects nothing that has already been written.
DAST_AUTH_MODE=db-insert DAST_AUTH_HEADER=api_access_token DAST_AUTH_PREFIX="" \
DAST_TOKEN_INSERT_SQL="INSERT INTO tokens (api_token, role_id) VALUES ('%TOKEN%', 1);" \
SHIM_INSERT_RC=1 \
    expect "db-insert: a failed INSERT is a loud skip" not-run 0
insert_token=$(sed -n 's/^::add-mask:://p' "$WORK/log" | grep '^nova-ci-apiscan-' | head -1 || true)
# `|| true` on both: with pipefail set, a grep that matches nothing aborts the whole
# harness instead of failing this one assertion — and "matches nothing" is exactly what
# the mutation of this guard produces, so without it the guard could never be watched
# to fail cleanly.
mask_ln=$(grep -nF "::add-mask::${insert_token:-__none__}" "$WORK/log" | head -1 | cut -d: -f1 || true)
echo_ln=$(grep -nF "${insert_token:-__none__}" "$WORK/log" | grep -v '::add-mask::' | head -1 | cut -d: -f1 || true)
if [ -n "$insert_token" ] && [ -n "$mask_ln" ] && [ -n "$echo_ln" ] && [ "$mask_ln" -lt "$echo_ln" ]; then
    echo "ok   the db-insert token is masked before anything can echo it"; pass=$((pass + 1))
else
    echo "FAIL the token reached the log before its ::add-mask:: (mask line ${mask_ln:-none}, first echo line ${echo_ln:-none})"
    fail=$((fail + 1))
fi
# A loud skip nobody can act on is a dead end, and "the migration may not have created
# the table" was a guess: the role_id subquery matching no row fails identically.
if grep -q 'relation "tokens" does not exist' "$WORK/log"; then
    echo "ok   psql's own output is printed, not discarded"; pass=$((pass + 1))
else
    echo "FAIL the INSERT failure printed no evidence"; fail=$((fail + 1))
fi
if grep -q 'role subquery matched no row' "$WORK/report"; then
    echo "ok   the skip names both plausible causes, not one guess"; pass=$((pass + 1))
else
    echo "FAIL the skip still names a single guessed cause"; fail=$((fail + 1))
fi

# A mode with no INSERT is a broken configuration, not a scan without auth.
DAST_AUTH_MODE=db-insert DAST_TOKEN_INSERT_SQL="" \
    expect "db-insert without token-insert-sql is a scanner error" error 2

# --- env-token: the app is handed the token, no database involved ---------------------
# novatalks.dialer's auth middleware accepts any token listed in API_ACCESS_TOKENS and
# short-circuits before it would call the engine. So there is nothing to seed and nothing
# to SELECT — generate a token, hand it to the app, inject the same one into ZAP.
DAST_AUTH_MODE=env-token DAST_TOKEN_ENV_VAR=API_ACCESS_TOKENS \
DAST_AUTH_HEADER=api_access_token DAST_AUTH_PREFIX="" \
SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "env-token mode: generate, export, inject" clean 0

# The same value must reach both sides, or the scan runs unauthenticated and says nothing.
env_token=$(sed -n 's/^::add-mask:://p' "$WORK/log" | grep '^nova-ci-apiscan-' | head -1 || true)
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

# login mode still works unchanged (core), with the default Authorization/Bearer header
SHIM_ZAP_RC=1 SHIM_ZAP_CONSOLE="FAIL-NEW: Some Critical Alert [90001] x 2
WARN-NEW: Some Warning Alert [10038] x 5
FAIL-NEW: 2	FAIL-INPROG: 0	WARN-NEW: 5	WARN-INPROG: 0	INFO: 0	IGNORE: 0	PASS: 30" \
    expect "login mode still injects Authorization: Bearer" findings 0
assert_zap_flag "login mode keeps the Bearer prefix" 'replacement=Bearer '

# The prefix surviving in the -z string is not the same as it surviving into ZAP.
# zap-api-scan.py runs that string through shlex.split() before passing it on
# (zap_common.py: add_zap_options), so an unquoted `replacement=Bearer <token>` arrives
# as two arguments: the header is set to a bare `Bearer` and the token is dropped as a
# stray positional. The scan then runs unauthenticated and reports a perfectly plausible
# result — the "it produced the output a working run produces" failure this whole action
# is built to refuse. So reproduce ZAP's own parse rather than asserting on the raw
# string, which passes either way.
assert_shlex_element() { # assert_shlex_element <name> <extended-regex the whole element must match>
    local name="$1" want="$2" zap_z
    zap_z="$(awk '/^-z$/{getline; print; exit}' "$WORK/zap-argv")"
    if [ -z "$zap_z" ]; then
        echo "FAIL $name — no -z argument in the recorded ZAP argv"; fail=$((fail + 1)); return
    fi
    if printf '%s' "$zap_z" \
        | python3 -c 'import shlex,sys; print("\n".join(shlex.split(sys.stdin.read())))' \
        | grep -qxE -- "$want"; then
        echo "ok   $name"; pass=$((pass + 1))
    else
        echo "FAIL $name — no shlex element matched: $want"
        printf '%s' "$zap_z" \
            | python3 -c 'import shlex,sys; print("\n".join(shlex.split(sys.stdin.read())))' \
            | sed 's/^/     /'
        fail=$((fail + 1))
    fi
}
assert_shlex_element "the Bearer prefix and the token reach ZAP as one argument" \
    '^replacer\.full_list\(0\)\.replacement=Bearer .+$'
assert_shlex_element "the header name reaches ZAP as one argument" \
    '^replacer\.full_list\(0\)\.matchstr=Authorization$'

# --- a boot failure and a setup failure are different things ---------------------------
# They used to arrive as the same four words: `docker exec` against a container that
# never started fails on its own, so an image that did not boot reported "database setup
# failed". One message for two causes is the defect this action exists to refuse, applied
# to its own diagnostics.
SHIM_APP_STATE="false" expect "a container that never started says so" not-run 0
if grep -q "the image did not start" "$WORK/report"; then
    echo "ok   the report names the boot failure, not the setup command"; pass=$((pass + 1))
else
    echo "FAIL the report still blames the setup command for a container that never started"
    fail=$((fail + 1))
fi

# The loud skip is only actionable with the evidence behind it. `>/dev/null 2>&1` on the
# setup command made every failure here a dead end.
SHIM_DBSETUP_RC=1 SHIM_DBSETUP_OUT="Error: P3009 migrate found failed migrations" \
DAST_SETUP_CMD="npm run db:setup:prod" \
    expect "a failing setup command is still a loud skip" not-run 0
if grep -q "P3009 migrate found failed migrations" "$WORK/log"; then
    echo "ok   the setup command's own output reaches the step log"; pass=$((pass + 1))
else
    echo "FAIL the setup command failed with its output discarded — nothing to act on"
    fail=$((fail + 1))
fi

# The generated admin password is masked before the container that could echo it exists,
# not just before ZAP runs — this script now prints container output on failure.
if grep -q "::add-mask::" "$WORK/log"; then
    echo "ok   the generated admin password is masked before any container output is printed"
    pass=$((pass + 1))
else
    echo "FAIL the admin password was never masked, and failure paths print container logs"
    fail=$((fail + 1))
fi

# --- the image usually sets itself up -------------------------------------------------
# Both images wired up so far migrate and seed from their own ENTRYPOINT. novatalks.core
# cannot do it any other way: its runtime stage installs nodejs-24 and not npm, so
# `npm run db:setup:prod` over `docker exec` answered `sh: npm: not found`. So an empty
# setup-command must mean "skip the exec", not "fall back to the old default".
DAST_SETUP_CMD="" expect "no setup-command runs no setup exec" clean 0
if grep -qE "^exec .*(db:setup|npm run)" "$WORK/dockerlog"; then
    echo "FAIL an empty setup-command still ran a setup exec"; fail=$((fail + 1))
else
    echo "ok   an empty setup-command runs no setup exec at all"; pass=$((pass + 1))
fi
if grep -q "entrypoint migrates and seeds" "$WORK/log"; then
    echo "ok   and says so, rather than skipping silently"; pass=$((pass + 1))
else
    echo "FAIL the skip is silent — a reader cannot tell it from a setup that ran"
    fail=$((fail + 1))
fi

# The escape hatch still works for an image that does not self-setup.
DAST_SETUP_CMD="npm run db:setup:prod" expect "an explicit setup-command still runs" clean 0
if grep -qE "^exec .*db:setup:prod" "$WORK/dockerlog"; then
    echo "ok   an explicit setup-command is still executed"; pass=$((pass + 1))
else
    echo "FAIL an explicit setup-command was dropped"; fail=$((fail + 1))
fi

# Prisma reads DATABASE_URL and nothing else; the telegram connector's entrypoint died on
# P1012 "Environment variable not found: DATABASE_URL" because this script only passed the
# discrete DATABASE_* vars the Sequelize repositories use. Both conventions, same values.
if grep -qE "DATABASE_URL=postgresql://postgres:password@127\.0\.0\.1:5432/db_name" "$WORK/dockerlog"; then
    echo "ok   the app container gets DATABASE_URL for Prisma, built from the same values"
    pass=$((pass + 1))
else
    echo "FAIL no DATABASE_URL on the app container — Prisma repositories cannot migrate"
    fail=$((fail + 1))
fi

# --- postgres, the dependency that silently was not there ------------------------------
# Same regression as dast/scan.sh's: the CloudNativePG operator image has no entrypoint,
# so `docker run -d` started bash, bash exited, and pg_isready failed for a minute while
# the loop fell through without a word. Every api-scan ever run reported
# "the image did not come up" for a database that was never started.
SHIM_PG_READY_RC=1 expect "a postgres that never becomes ready is a loud skip" not-run 0
if grep -q "postgres never became ready" "$WORK/report"; then
    echo "ok   the skip names postgres, not the application image"; pass=$((pass + 1))
else
    echo "FAIL the skip still blames the image"; fail=$((fail + 1))
fi

SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" expect "a normal run still scans" clean 0
if grep -E "^run .*--name nova-pg" "$WORK/dockerlog" | grep -qE " postgres:[0-9]"; then
    echo "ok   postgres comes from the Docker Official image"; pass=$((pass + 1))
else
    echo "FAIL nova-pg is not a postgres:N image"; fail=$((fail + 1))
fi

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
unset DAST_API_SCAN_MODE

# --- which repository is being scanned is an input, not an accident of who is running --
# Every caller until ci-dast-pentest.yaml was the reusable build workflow, running in the
# product repository's own context, so GITHUB_REPOSITORY happened to name the scanned
# repository. The pentest workflow runs in nova.ci, where ${GITHUB_REPOSITORY##*/} is
# `nova.ci` and novatalks.core would silently have taken postgres:16.
assert_pg_image() { # assert_pg_image <name> <expected image>
    local got
    got="$(grep -E '^run .*--name nova-pg' "$WORK/dockerlog" | grep -oE 'postgres:[^ ]+' | head -1 || true)"
    if [ "$got" = "$2" ]; then
        echo "ok   $1"; pass=$((pass + 1))
    else
        echo "FAIL $1 — expected $2, got '${got:-none}'"; fail=$((fail + 1))
    fi
}

DAST_TARGET_REPO=novatalks.core GITHUB_REPOSITORY=novaitdevteam/nova.ci \
SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "target-repository set: the scan still runs" clean 0
assert_pg_image "target-repository picks novatalks.core's postgres, not the runner's" postgres:17.9-trixie
# Right is half of it; visible is the other half. The choice was silent before, which is
# why getting it wrong would never have been noticed.
if grep -q "DAST API postgres: postgres:17.9-trixie — chosen for 'novatalks.core' (from the target-repository input)" "$WORK/log"; then
    echo "ok   the postgres choice and its source are logged"; pass=$((pass + 1))
else
    echo "FAIL the postgres choice is still silent"; fail=$((fail + 1))
fi
unset DAST_TARGET_REPO GITHUB_REPOSITORY

# Unset: byte-identical to what every existing caller does today.
GITHUB_REPOSITORY=novaitdevteam/novatalks.core \
SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "target-repository unset: the scan still runs" clean 0
assert_pg_image "an unset input falls back to GITHUB_REPOSITORY" postgres:17.9-trixie
if grep -q "(from GITHUB_REPOSITORY)" "$WORK/log"; then
    echo "ok   the fallback names itself as the fallback"; pass=$((pass + 1))
else
    echo "FAIL the log does not say where the repository name came from"; fail=$((fail + 1))
fi
unset GITHUB_REPOSITORY

GITHUB_REPOSITORY=novaitdevteam/nova.chatsconnector.telegram-client-api \
SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "every other repository still resolves through the fallback" clean 0
assert_pg_image "a connector takes postgres:16" postgres:16
unset GITHUB_REPOSITORY

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
