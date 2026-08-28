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

# Two workspace fixtures for the --env-file scenarios: one carries a .env.example (with
# a comment line that must never survive into the container), the other has none. Kept
# apart from $WORK's own root so the six pre-existing scenarios, which default
# GITHUB_WORKSPACE to $WORK, never see either.
WS_WITH_ENV="$WORK/ws-with-envfile"
WS_WITHOUT_ENV="$WORK/ws-without-envfile"
mkdir -p "$WS_WITH_ENV" "$WS_WITHOUT_ENV"
cat > "$WS_WITH_ENV/.env.example" <<'ENVEX'
# leaked secrets would live below this line — must never reach the container
FILE_DRIVER=s3
AWS_S3_BUCKET=example-bucket
ENVEX

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
    : >"$WORK/zap.md"; : >"$WORK/dast.env"

    set +e
    PATH="$WORK/bin:$PATH" \
    SHIM_LOG="$WORK/dockerlog" SHIM_ZAP_OUT="$WORK/zap.md" \
    DAST_IMAGE="ghcr.io/x/y:z" \
    DAST_PORT="3000" \
    DAST_HEALTH_PATH="/" \
    DAST_BOOT_TIMEOUT="6" \
    DAST_NEEDS_DB="${DAST_NEEDS_DB:-true}" \
    DAST_PG_IMAGE="postgres:16" \
    DAST_ENV_FILE="${DAST_ENV_FILE:-.env.example}" \
    GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$WORK}" \
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
    # Only cleanup() removes all three containers in one call; the pre-flight `docker rm
    # -f` calls earlier in scan.sh remove them separately (nova-pg/nova-redis together,
    # nova-app on its own). Matching the exact three-name line proves the EXIT trap ran,
    # rather than just proving a pre-flight removal happened before anything started.
    if grep -qx 'rm -f nova-app nova-pg nova-redis' "$WORK/dockerlog"; then
        echo "ok   $1"; pass=$((pass + 1))
    else
        echo "FAIL $1 — containers were not torn down"; fail=$((fail + 1))
    fi
}

assert_no_db_containers() { # assert_no_db_containers <name>
    if grep -qE '^run .*--name nova-(pg|redis)\b' "$WORK/dockerlog"; then
        echo "FAIL $1 — postgres/redis were started"; fail=$((fail + 1))
    else
        echo "ok   $1"; pass=$((pass + 1))
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
assert_cleanup "app-refuses-to-start run still tears containers down"

# novatalks.ui's production path: static assets behind nginx, no database at all.
DAST_NEEDS_DB=false SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_REPORT="PASS: nothing to see" \
    expect "no-database app still boots and scans clean" clean 0
assert_cleanup "no-db run still tears containers down"
assert_no_db_containers "no-db run never starts postgres or redis"

# novatalks.core's production path: FILE_DRIVER=s3 and friends live in .env.example,
# not in this repo, so they must reach the app container without ever being typed here.
GITHUB_WORKSPACE="$WS_WITH_ENV" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_REPORT="PASS: everything" \
    expect "an existing .env.example is passed via --env-file" clean 0
assert_cleanup "env-file run tears containers down"
if grep -qE -- '--name nova-app.*--env-file [^ ]*dast\.env.* -e DATABASE_HOST=127\.0\.0\.1' "$WORK/dockerlog"; then
    echo "ok   --env-file is present and precedes the -e overrides"; pass=$((pass + 1))
else
    echo "FAIL --env-file missing, or not ahead of the explicit -e overrides"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
fi

GITHUB_WORKSPACE="$WS_WITHOUT_ENV" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_REPORT="PASS: everything" \
    expect "no .env.example — scan proceeds exactly as before" clean 0
assert_cleanup "no-env-file run still tears containers down"
if grep -qE -- '--name nova-app.*--env-file' "$WORK/dockerlog"; then
    echo "FAIL --env-file flag present despite no .env.example existing"; fail=$((fail + 1))
else
    echo "ok   no --env-file flag when there is no .env.example"; pass=$((pass + 1))
fi

GITHUB_WORKSPACE="$WS_WITH_ENV" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_REPORT="PASS: everything" \
    expect "comment lines are stripped before reaching the app container" clean 0
if [ -f "$WORK/dast.env" ] && ! grep -q '^#' "$WORK/dast.env" && grep -q '^FILE_DRIVER=s3$' "$WORK/dast.env"; then
    echo "ok   comment stripped, KEY=value lines survive"; pass=$((pass + 1))
else
    echo "FAIL comment line leaked into the temporary env file, or content missing"
    sed 's/^/     /' "$WORK/dast.env" 2>/dev/null || echo "     (no temp env file written)"
    fail=$((fail + 1))
fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
