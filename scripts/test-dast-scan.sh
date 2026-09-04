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
WS_ALL_FILTERED="$WORK/ws-all-filtered-envfile"
WS_TRAILING_COMMENT="$WORK/ws-trailing-comment-envfile"
WS_QUOTED="$WORK/ws-quoted-envfile"
mkdir -p "$WS_WITH_ENV" "$WS_WITHOUT_ENV" "$WS_ALL_FILTERED" "$WS_TRAILING_COMMENT" "$WS_QUOTED"
cat > "$WS_WITH_ENV/.env.example" <<'ENVEX'
# leaked secrets would live below this line — must never reach the container
FILE_DRIVER=s3
AWS_S3_BUCKET=example-bucket
MESSAGE_EXTERNAL_SOURCE_LAST_ID
ENVEX
# A file that exists but leaves nothing after both filters — only comments and bare
# keys, no KEY=value line at all.
cat > "$WS_ALL_FILTERED/.env.example" <<'ENVEX'
# nothing usable below this line
SOME_BARE_KEY
ANOTHER_BARE_KEY
ENVEX
# The novatalks.core regression fixture: a clean NODE_ENV (must be dropped by name, not
# by the comment filter), one value with a trailing ` //` comment, one with a trailing
# ` #` comment, a URL whose own `//` has no preceding whitespace (must survive), and one
# plain value (must survive) — so seeded/dropped counts land on 2 seeded, 2
# comment-dropped, 1 NODE_ENV-dropped.
cat > "$WS_TRAILING_COMMENT/.env.example" <<'ENVEX'
NODE_ENV=production
LOG_LEVEL=debug // change to info in prod
RATE_LIMIT=100 # requests per minute
EXTERNAL_URL=https://example.com
DATABASE_POOL=5
ENVEX
# nova.chatsconnector.telegram-client-api's actual .env.example: a double-quoted
# DATABASE_URL (dotenv strips the quotes; Docker's --env-file does not, and Prisma
# refused the leading '"' outright), a single-quoted value, a value with an inner quote
# that must survive, and a value with only a leading quote and no closing one, which
# must be left exactly as written since there is no matching pair to strip.
cat > "$WS_QUOTED/.env.example" <<'ENVEX'
DATABASE_URL="postgresql://user:!1q2w3e@localhost:5432/novatalks_db"
SINGLE_QUOTED='hello world'
INNER_QUOTE=va"lu"e
LEADING_ONLY="unterminated
ENVEX
# The signal-connector regression fixture: an APP_PORT that disagrees with the port
# scan.sh is told to poll/scan. Must never win — the action forces PORT/APP_PORT to
# DAST_PORT after --env-file regardless of what the template says.
WS_WRONG_PORT="$WORK/ws-wrong-port-envfile"
mkdir -p "$WS_WRONG_PORT"
cat > "$WS_WRONG_PORT/.env.example" <<'ENVEX'
APP_PORT=5555
ENVEX
# The novatalks.dialer regression fixture: MEMORY_RSS_THRESHOLD is declared
# `Joi.number().integer().default(0)`, a perfectly good default, but .env.example line
# 13 leaves it blank. Joi only applies a default when a value is undefined, and an
# empty string is a value — passing it through crashed boot with "must be a number"
# even though the app never needed the line at all. One truly empty value, one
# whitespace-only value (not a real value either, just untrimmed template noise), and
# one real value that must survive untouched.
WS_EMPTY_VALUE="$WORK/ws-empty-value-envfile"
mkdir -p "$WS_EMPTY_VALUE"
printf 'MEMORY_RSS_THRESHOLD=\nWHITESPACE_ONLY=   \nLOG_LEVEL=debug\n' > "$WS_EMPTY_VALUE/.env.example"

pass=0
fail=0

# A completed scan always prints exactly one tally line, so every fixture standing in
# for a completed scan needs one. The scenarios that assert something about counting
# spell their own out; these are the ones where the console content is irrelevant.
ZAP_CLEAN_CONSOLE="PASS: everything
FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 0	WARN-INPROG: 0	INFO: 0	IGNORE: 0	PASS: 40"

# docker shim. Records every invocation so cleanup can be asserted, and dispatches on
# the subcommand so "run the app" and "run ZAP" can fail independently. For the app
# container specifically, it also snapshots whatever file --env-file points at, at
# invocation time — scan.sh's own EXIT trap deletes that file as soon as the process
# exits, before the harness's own post-run assertions ever get to look at it, so
# anything that wants to inspect its content has to capture it here instead.
cat > "$WORK/bin/docker" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "${SHIM_LOG:?}"
case "$1" in
    run)
        case "$*" in
            *zaproxy*)
                # Two separate channels, because the real zap-baseline.py has two.
                # -w writes the traditional "ZAP Scanning Report" markdown; WARN-NEW
                # never appears in it. The per-rule WARN-NEW lines go to stdout only.
                # A shim that conflates them cannot catch a scan.sh that counts the
                # wrong stream — which is exactly the bug this file once encoded.
                printf '%s\n' "${SHIM_ZAP_MD:-# ZAP Scanning Report

## Summary of Alerts
| Risk Level | Number of Alerts |
| Informational | 0 |}" > "${SHIM_ZAP_OUT:?}"
                printf '%s\n' "${SHIM_ZAP_CONSOLE:-PASS: everything
FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 0	WARN-INPROG: 0	INFO: 0	IGNORE: 0	PASS: 40}"
                exit "${SHIM_ZAP_RC:-0}" ;;
            *nova-nats*)
                # Separate control from SHIM_APP_RC: some scenarios need NATS to start
                # fine while the application container itself refuses to, or vice versa.
                exit "${SHIM_NATS_RUN_RC:-0}" ;;
            *)
                if [ -n "${SHIM_ENVFILE_SNAPSHOT:-}" ]; then
                    prev=""
                    for arg in "$@"; do
                        [ "$prev" = "--env-file" ] && cp "$arg" "$SHIM_ENVFILE_SNAPSHOT" 2>/dev/null
                        prev="$arg"
                    done
                fi
                exit "${SHIM_APP_RC:-0}" ;;
        esac ;;
    exec)
        # pg_isready is the postgres readiness oracle. It has to be controllable: the
        # whole point of the new guard is what happens when it never succeeds, and with
        # a shim that always says yes that path is unreachable.
        case "$*" in
            *pg_isready*) exit "${SHIM_PG_READY_RC:-0}" ;;
            *) exit 0 ;;
        esac ;;
    rm|pull|logs) exit 0 ;;
    *) exit 0 ;;
esac
SHIM
chmod +x "$WORK/bin/docker"

# curl shim: the wait-loops' only oracle. SHIM_CURL_RC=0 means the app answered. The
# NATS readiness poll (http://127.0.0.1:8222/healthz) gets its own SHIM_NATS_CURL_RC,
# falling back to SHIM_CURL_RC when unset — needed to prove the readiness check is load
# -bearing: a scenario can make NATS never answer while the app health probe still would.
cat > "$WORK/bin/curl" <<'SHIM'
#!/usr/bin/env bash
for arg in "$@"; do
    case "$arg" in
        *8222/healthz*)
            rc="${SHIM_NATS_CURL_RC:-${SHIM_CURL_RC:-0}}"
            [ "$rc" = "0" ] && { printf '200'; exit 0; }
            printf '000'; exit 7 ;;
    esac
done
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
    : >"$WORK/zap.md"; : >"$WORK/dast.env"; : >"$WORK/envfile-snapshot"
    : >"$WORK/report"; rm -f "$WORK/zap-console.log"

    set +e
    PATH="$WORK/bin:$PATH" \
    SHIM_LOG="$WORK/dockerlog" SHIM_ZAP_OUT="$WORK/zap.md" SHIM_ENVFILE_SNAPSHOT="$WORK/envfile-snapshot" \
    DAST_IMAGE="ghcr.io/x/y:z" \
    DAST_PORT="3000" \
    DAST_HEALTH_PATH="${DAST_HEALTH_PATH:-/}" \
    DAST_BOOT_TIMEOUT="6" \
    DAST_NEEDS_DB="${DAST_NEEDS_DB:-true}" \
    DAST_NEEDS_NATS="${DAST_NEEDS_NATS:-false}" \
    DAST_EXTRA_ENV="${DAST_EXTRA_ENV:-}" \
    GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$WORK}" \
    ZAP_IMAGE="ghcr.io/zaproxy/zaproxy@sha256:deadbeef" \
    DAST_ACTION_ROOT="${DAST_ACTION_ROOT:-$ROOT/.github/actions/dast}" \
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

assert_cleanup() { # assert_cleanup <name>
    # Only cleanup() removes all four containers in one call; the pre-flight `docker rm
    # -f` calls earlier in scan.sh remove them separately (nova-pg/nova-redis together,
    # nova-nats and nova-app each on their own). Matching the exact four-name line proves
    # the EXIT trap ran, rather than just proving a pre-flight removal happened before
    # anything started.
    if grep -qx 'rm -f nova-app nova-pg nova-redis nova-nats' "$WORK/dockerlog"; then
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

SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "app boots, ZAP finds nothing" clean 0
assert_cleanup "clean run tears containers down"
assert_findings "a tally of all zeroes counts zero" 0
# /zap/wrk is a bind mount of RUNNER_TEMP on a pooled runner; the image's own uid 1000
# may not be able to write there, and write_report failing would red a trunk build.
if grep -qE '^run .*zaproxy.*' "$WORK/dockerlog" && grep -qE -- '--user [0-9]+:[0-9]+' "$WORK/dockerlog"; then
    echo "ok   ZAP runs as the runner's own uid:gid"; pass=$((pass + 1))
else
    echo "FAIL ZAP container is not pinned to the runner's uid:gid"; fail=$((fail + 1))
fi

SHIM_CURL_RC=0 SHIM_ZAP_RC=2 SHIM_ZAP_CONSOLE="WARN-NEW: 3 things
WARN-NEW: x
WARN-NEW: y
FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 4	WARN-INPROG: 0	INFO: 0	IGNORE: 0	PASS: 40" \
    expect "ZAP warnings are findings, not failure" findings 0
# Deliberately disagreeing: three per-rule WARN-NEW lines but a tally of 4. If the count
# ever came from the per-rule lines again, this would read 3 and the assertion below
# would catch it — matching fixtures (three lines, a tally of 3) let a reversion to
# counting per-rule lines pass unnoticed, which is exactly what happened here before.
assert_findings "the tally line is the warning count, not the per-rule lines" 4
assert_cleanup "findings run tears containers down"

# The regression this whole rewiring exists for. zap-baseline.py -w writes the
# traditional markdown report, which names alerts but never prints WARN-NEW; the
# WARN-NEW lines are on stdout only. Counting the -w file therefore yields a permanent
# zero — every run "🟢 clean", including one with twenty warnings. The md fixture below
# is deliberately full of alert text and free of any tally line: a scan.sh that counts the
# file rather than the console stream reports clean here and fails this scenario.
SHIM_CURL_RC=0 SHIM_ZAP_RC=2 \
SHIM_ZAP_MD="# ZAP Scanning Report

## Summary of Alerts
| Risk Level | Number of Alerts |
| Medium | 2 |
| Low | 1 |

## Medium
### Content Security Policy (CSP) Header Not Set
### Missing Anti-clickjacking Header

## Low
### X-Content-Type-Options Header Missing" \
SHIM_ZAP_CONSOLE="WARN-NEW: Content Security Policy (CSP) Header Not Set [10038] x 4
WARN-NEW: Missing Anti-clickjacking Header [10020] x 1
WARN-NEW: X-Content-Type-Options Header Missing [10021] x 6
FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 3	WARN-INPROG: 0	INFO: 0	IGNORE: 0	PASS: 40" \
    expect "warnings are counted from the console stream, not the -w markdown report" findings 0
assert_findings "a markdown report with alert text but no WARN-NEW still counts 3" 3
if grep -q 'Summary of Alerts' "$WORK/report"; then
    echo "ok   the .report still carries the human-readable markdown report"; pass=$((pass + 1))
else
    echo "FAIL the .report lost the markdown report body"; fail=$((fail + 1))
fi
if [ -f "$WORK/zap-console.log" ]; then
    echo "FAIL the ZAP console log survived the process — it must be cleaned up like the env file"
    fail=$((fail + 1))
else
    echo "ok   the ZAP console log is deleted once the process exits"; pass=$((pass + 1))
fi

# The boot probe polls the health path; ZAP scans the root. The summary and the report
# header must name the URL that was scanned — on novatalks.ui /livez 404s, so naming it
# as the "Target" would advertise a 404 as the thing under test.
DAST_HEALTH_PATH="/livez" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 \
    expect "the health path is polled but the root is scanned" clean 0
if grep -q 'Target: http://127.0.0.1:3000$' "$WORK/report" && ! grep -q 'livez' "$WORK/report"; then
    echo "ok   the report header names the scanned URL, not the health URL"; pass=$((pass + 1))
else
    echo "FAIL the report header names the health URL rather than the ZAP target"
    sed 's/^/     /' "$WORK/report" | head -8
    fail=$((fail + 1))
fi
if grep -qE '^run .*zaproxy.* -t http://127\.0\.0\.1:3000( |$)' "$WORK/dockerlog"; then
    echo "ok   ZAP is pointed at the root, not the health path"; pass=$((pass + 1))
else
    echo "FAIL ZAP target argument changed"; sed 's/^/     /' "$WORK/dockerlog"; fail=$((fail + 1))
fi

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
DAST_NEEDS_DB=false SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "no-database app still boots and scans clean" clean 0
assert_cleanup "no-db run still tears containers down"
assert_no_db_containers "no-db run never starts postgres or redis"

# novatalks.core's production path: FILE_DRIVER=s3 and friends live in .env.example,
# not in this repo, so they must reach the app container without ever being typed here.
GITHUB_WORKSPACE="$WS_WITH_ENV" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "an existing .env.example is passed via --env-file" clean 0
assert_cleanup "env-file run tears containers down"
if grep -qE -- '--name nova-app.*--env-file [^ ]*dast\.env.* -e DATABASE_HOST=127\.0\.0\.1' "$WORK/dockerlog"; then
    echo "ok   --env-file is present and precedes the -e overrides"; pass=$((pass + 1))
else
    echo "FAIL --env-file missing, or not ahead of the explicit -e overrides"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
fi
# Real regression coverage for cleanup()'s rm -f, not just a passing trap call: this
# line has already been deleted once on this branch, so assert what it's actually for
# — the file that may carry credentials must not survive the process. Content was
# already captured into the snapshot above, at invocation time, so checking existence
# of the real path here (after the process has exited and cleanup() has run) doesn't
# need the file to still hold anything.
if [ ! -f "$WORK/dast.env" ]; then
    echo "ok   the temporary env file is deleted once the process exits"; pass=$((pass + 1))
else
    echo "FAIL the temporary env file was left behind after the process exited"; fail=$((fail + 1))
fi

GITHUB_WORKSPACE="$WS_WITHOUT_ENV" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "no .env.example — scan proceeds exactly as before" clean 0
assert_cleanup "no-env-file run still tears containers down"
if grep -qE -- '--name nova-app.*--env-file' "$WORK/dockerlog"; then
    echo "FAIL --env-file flag present despite no .env.example existing"; fail=$((fail + 1))
else
    echo "ok   no --env-file flag when there is no .env.example"; pass=$((pass + 1))
fi

# scan.sh's own cleanup() deletes the temp env file the instant the process exits (it
# may carry credentials, and self-hosted runners are pooled/reused, not thrown away
# between jobs), so these two assertions read the docker shim's snapshot — taken at
# `docker run` invocation time, before that trap ever fires — rather than $WORK/dast.env.
GITHUB_WORKSPACE="$WS_WITH_ENV" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "comment and bare-key lines are stripped before reaching the app container" clean 0
if [ -f "$WORK/envfile-snapshot" ] && ! grep -q '^#' "$WORK/envfile-snapshot" && grep -q '^FILE_DRIVER=s3$' "$WORK/envfile-snapshot"; then
    echo "ok   comment stripped, KEY=value lines survive"; pass=$((pass + 1))
else
    echo "FAIL comment line leaked into the temporary env file, or content missing"
    sed 's/^/     /' "$WORK/envfile-snapshot" 2>/dev/null || echo "     (no snapshot captured)"
    fail=$((fail + 1))
fi
if grep -q '^MESSAGE_EXTERNAL_SOURCE_LAST_ID$' "$WORK/envfile-snapshot" 2>/dev/null; then
    echo "FAIL bare-key line (no '=') leaked into the temporary env file"
    fail=$((fail + 1))
else
    echo "ok   bare-key line without '=' is dropped, not passed through from our own env"; pass=$((pass + 1))
fi

# .env.example exists but both filters leave nothing (only comments and bare keys):
# scan.sh's `|| true` guard on the filter pipeline covers exactly this — the run must
# still succeed, and whatever --env-file ends up pointing at must carry nothing.
GITHUB_WORKSPACE="$WS_ALL_FILTERED" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "an .env.example with only comments/bare keys leaves nothing to pass through" clean 0
assert_cleanup "all-filtered run tears containers down"
if [ -s "$WORK/envfile-snapshot" ]; then
    echo "FAIL all-filtered .env.example should leave an empty --env-file target"
    sed 's/^/     /' "$WORK/envfile-snapshot"
    fail=$((fail + 1))
else
    echo "ok   all-filtered .env.example leaves nothing for --env-file to pass through"; pass=$((pass + 1))
fi

# Defect regression: novatalks.core's .env.example carries `NODE_ENV=production //
# production, development, test`. Docker's --env-file strips whole-line comments only,
# never a trailing one, so the literal comment text became part of NODE_ENV and
# Sequelize CLI found no config section by that name — the engine never booted. Two
# rules, checked independently: any line with a trailing ` //` or ` #` comment is
# dropped outright, and NODE_ENV is dropped by name regardless of its own formatting.
GITHUB_WORKSPACE="$WS_TRAILING_COMMENT" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "an env file with trailing comments and NODE_ENV still boots clean" clean 0
assert_cleanup "trailing-comment run tears containers down"
if grep -q '^LOG_LEVEL=' "$WORK/envfile-snapshot" 2>/dev/null; then
    echo "FAIL a value with a trailing // comment leaked into the temporary env file"
    fail=$((fail + 1))
else
    echo "ok   a value with a trailing // comment is dropped"; pass=$((pass + 1))
fi
if grep -q '^RATE_LIMIT=' "$WORK/envfile-snapshot" 2>/dev/null; then
    echo "FAIL a value with a trailing # comment leaked into the temporary env file"
    fail=$((fail + 1))
else
    echo "ok   a value with a trailing # comment is dropped"; pass=$((pass + 1))
fi
if grep -q '^EXTERNAL_URL=https://example.com$' "$WORK/envfile-snapshot" 2>/dev/null; then
    echo "ok   a URL value whose // has no preceding space survives"; pass=$((pass + 1))
else
    echo "FAIL a URL value survived filtering incorrectly, or is missing"
    sed 's/^/     /' "$WORK/envfile-snapshot" 2>/dev/null || echo "     (no snapshot captured)"
    fail=$((fail + 1))
fi
if grep -q '^NODE_ENV=' "$WORK/envfile-snapshot" 2>/dev/null; then
    echo "FAIL NODE_ENV reached the temporary env file, and so would have reached the container"
    fail=$((fail + 1))
else
    echo "ok   NODE_ENV never reaches the container regardless of its own formatting"; pass=$((pass + 1))
fi
if grep -q 'seeded 2 variable(s); dropped 2 line(s) with a trailing comment, 1 NODE_ENV line(s), 0 line(s) with an empty value' "$WORK/log"; then
    echo "ok   seeded/dropped counts are logged, by rule"; pass=$((pass + 1))
else
    echo "FAIL seeded/dropped counts are missing from the output"
    sed 's/^/     /' "$WORK/log"
    fail=$((fail + 1))
fi

# Defect regression #4: novatalks.dialer's .env.example leaves MEMORY_RSS_THRESHOLD
# blank. Joi's `.default(0)` only fires on an undefined value, and an empty string is a
# value, so passing it through overrode the default with something Joi's own
# `.number()` check then rejected outright, and the app never booted. Same family as
# NODE_ENV, the trailing comment and the port: the action must not let a blank template
# line become a literal empty-string override.
GITHUB_WORKSPACE="$WS_EMPTY_VALUE" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "an env file with an empty and a whitespace-only value still boots clean" clean 0
assert_cleanup "empty-value run tears containers down"
if grep -q '^MEMORY_RSS_THRESHOLD=' "$WORK/envfile-snapshot" 2>/dev/null; then
    echo "FAIL a line with an empty value leaked into the temporary env file"
    fail=$((fail + 1))
else
    echo "ok   a line with an empty value is dropped"; pass=$((pass + 1))
fi
if grep -q '^WHITESPACE_ONLY=' "$WORK/envfile-snapshot" 2>/dev/null; then
    echo "FAIL a line whose value is only whitespace leaked into the temporary env file"
    fail=$((fail + 1))
else
    echo "ok   a line whose value is only whitespace is dropped"; pass=$((pass + 1))
fi
if grep -qx 'LOG_LEVEL=debug' "$WORK/envfile-snapshot" 2>/dev/null; then
    echo "ok   a line with a real value is kept"; pass=$((pass + 1))
else
    echo "FAIL a line with a real value was dropped, or is missing"
    sed 's/^/     /' "$WORK/envfile-snapshot" 2>/dev/null || echo "     (no snapshot captured)"
    fail=$((fail + 1))
fi
if grep -q 'seeded 1 variable(s); dropped 0 line(s) with a trailing comment, 0 NODE_ENV line(s), 2 line(s) with an empty value' "$WORK/log"; then
    echo "ok   the dropped-empty count appears in the log line"; pass=$((pass + 1))
else
    echo "FAIL the dropped-empty count is missing from the log line"
    sed 's/^/     /' "$WORK/log"
    fail=$((fail + 1))
fi

# Defect regression #1: nova.chatsconnector.telegram-client-api's .env.example carries
# DATABASE_URL="postgresql://user:!1q2w3e@localhost:5432/novatalks...". Docker's
# --env-file does not strip quotes the way dotenv does, so the container received a
# value whose first character is '"', and Prisma refused it outright — the engine never
# booted. Strip a matching pair of surrounding quotes only, nothing else.
GITHUB_WORKSPACE="$WS_QUOTED" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "an env file with quoted values still boots clean" clean 0
assert_cleanup "quoted-values run tears containers down"
if grep -qx 'DATABASE_URL=postgresql://user:!1q2w3e@localhost:5432/novatalks_db' "$WORK/envfile-snapshot" 2>/dev/null; then
    echo "ok   a double-quoted value arrives unquoted"; pass=$((pass + 1))
else
    echo "FAIL a double-quoted value kept its surrounding quotes, or is missing"
    sed 's/^/     /' "$WORK/envfile-snapshot" 2>/dev/null || echo "     (no snapshot captured)"
    fail=$((fail + 1))
fi
if grep -qx 'SINGLE_QUOTED=hello world' "$WORK/envfile-snapshot" 2>/dev/null; then
    echo "ok   a single-quoted value arrives unquoted"; pass=$((pass + 1))
else
    echo "FAIL a single-quoted value kept its surrounding quotes, or is missing"
    sed 's/^/     /' "$WORK/envfile-snapshot" 2>/dev/null || echo "     (no snapshot captured)"
    fail=$((fail + 1))
fi
if grep -qx 'INNER_QUOTE=va"lu"e' "$WORK/envfile-snapshot" 2>/dev/null; then
    echo "ok   a value with an inner quote keeps it"; pass=$((pass + 1))
else
    echo "FAIL a value with an inner quote was altered, or is missing"
    sed 's/^/     /' "$WORK/envfile-snapshot" 2>/dev/null || echo "     (no snapshot captured)"
    fail=$((fail + 1))
fi
if grep -qx 'LEADING_ONLY="unterminated' "$WORK/envfile-snapshot" 2>/dev/null; then
    echo "ok   a value with only a leading quote and no trailing one is left untouched"; pass=$((pass + 1))
else
    echo "FAIL a value with only a leading quote was altered, or is missing"
    sed 's/^/     /' "$WORK/envfile-snapshot" 2>/dev/null || echo "     (no snapshot captured)"
    fail=$((fail + 1))
fi

# Defect regression: nova.chatsconnector.signal-client-api's .env.example carried
# APP_PORT=5555 while its chart containerPort, its Dockerfile EXPOSE and the Resolve
# DAST target step all named 3000. The app booted on 5555, the wait-loop polled 3000,
# and a perfectly healthy boot reported "not run". The action must own the port exactly
# like it owns NODE_ENV and quoting: force PORT and APP_PORT to DAST_PORT after
# --env-file so the seeded template can never win.
GITHUB_WORKSPACE="$WS_WITH_ENV" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "PORT and APP_PORT are forced to the configured port" clean 0
if grep -qE -- '--name nova-app.*-e PORT=3000( |$)' "$WORK/dockerlog" && grep -qE -- '--name nova-app.*-e APP_PORT=3000( |$)' "$WORK/dockerlog"; then
    echo "ok   both PORT and APP_PORT are passed to the app container, both equal to DAST_PORT"; pass=$((pass + 1))
else
    echo "FAIL PORT and/or APP_PORT missing, or not equal to DAST_PORT"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
fi
if grep -qE -- '--env-file [^ ]*dast\.env.*-e PORT=3000.*-e APP_PORT=3000' "$WORK/dockerlog"; then
    echo "ok   PORT and APP_PORT appear after --env-file, so a seeded value loses"; pass=$((pass + 1))
else
    echo "FAIL PORT/APP_PORT do not follow --env-file on the command line"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
fi

# The wrong-port fixture: APP_PORT=5555 in .env.example, same shape as the real
# signal-connector regression. The seeded file itself still carries 5555 unmodified (the
# comment/bare-key/NODE_ENV/quote filters above have no reason to touch it), but the
# forced -e APP_PORT=3000 comes later on the command line and wins — docker's own
# last-value-wins rule for repeated -e flags of the same name.
GITHUB_WORKSPACE="$WS_WRONG_PORT" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "an APP_PORT seeded from .env.example does not change what is passed" clean 0
if grep -q '^APP_PORT=5555$' "$WORK/envfile-snapshot" 2>/dev/null; then
    echo "ok   the seeded APP_PORT=5555 still reaches --env-file unmodified"; pass=$((pass + 1))
else
    echo "FAIL the seeded APP_PORT line was unexpectedly filtered"
    sed 's/^/     /' "$WORK/envfile-snapshot" 2>/dev/null || echo "     (no snapshot captured)"
    fail=$((fail + 1))
fi
if grep -qE -- '--name nova-app.*-e APP_PORT=3000( |$)' "$WORK/dockerlog"; then
    echo "ok   the forced -e APP_PORT=3000 follows the seeded value and wins"; pass=$((pass + 1))
else
    echo "FAIL the forced APP_PORT is missing, or the seeded 5555 was passed instead"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
fi
# Same run: the wait-loop polls health_url and ZAP scans target, both built from
# DAST_PORT — the very value just forced onto the app container above. All three uses
# share the one variable, so a mismatch between what the container listens on and what
# gets polled/scanned is exactly the defect this scenario guards against.
if grep -qE -- '^run .*zaproxy.* -t http://127\.0\.0\.1:3000( |$)' "$WORK/dockerlog"; then
    echo "ok   ZAP is pointed at the same port forced onto the app container"; pass=$((pass + 1))
else
    echo "FAIL ZAP target port does not match the forced app container port"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
fi

# Defect regression #2: even with quotes stripped, .env.example's own DATABASE_URL names
# a different user/password/database than the postgres this script actually starts (it
# documents a developer's local setup, not this scan run). Prisma-based repositories
# have no discrete DATABASE_* vars to bind to, so an explicit DATABASE_URL — built from
# the very same values used for the discrete vars and for the postgres container this
# script starts — must reach the app container and win over whatever the example said.
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "DATABASE_URL is passed to the app container when the database is up" clean 0
if grep -qE -- '--name nova-app.*-e DATABASE_URL=postgresql://postgres:password@127\.0\.0\.1:5432/db_name( |$)' "$WORK/dockerlog"; then
    echo "ok   DATABASE_URL matches the user/password/db/port of the postgres this script started"; pass=$((pass + 1))
else
    echo "FAIL DATABASE_URL missing, or does not match the started postgres"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
fi

DAST_NEEDS_DB=false SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "DATABASE_URL is withheld when no database is started" clean 0
if grep -qE -- '--name nova-app.*-e DATABASE_URL=' "$WORK/dockerlog"; then
    echo "FAIL DATABASE_URL was passed despite DAST_NEEDS_DB=false"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
else
    echo "ok   DATABASE_URL is not passed when DAST_NEEDS_DB is false"; pass=$((pass + 1))
fi


# Per-repository escape hatch for a template placeholder in the product repo's own
# .env.example that a config validator rejects outright (this is what unblocked
# nova.chatsconnector.signal-client-api: S3_ENDPOINT=https://<account-id>.r2...
# is not a valid URL). extra-env applies -e flags after --env-file, so it overrides
# the seeded value of the same name rather than adding alongside a stale one.
GITHUB_WORKSPACE="$WS_WITH_ENV" DAST_EXTRA_ENV="FILE_DRIVER=override-value" \
    SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "an extra-env line reaches the application container as a -e flag" clean 0
if grep -qE -- '--name nova-app.*-e FILE_DRIVER=override-value( |$)' "$WORK/dockerlog"; then
    echo "ok   extra-env line reaches the app container as a -e flag"; pass=$((pass + 1))
else
    echo "FAIL extra-env line missing from the docker run invocation"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
fi
if grep -qE -- '--env-file [^ ]*dast\.env.*-e FILE_DRIVER=override-value' "$WORK/dockerlog"; then
    echo "ok   the extra-env -e flag appears after --env-file, so it wins over the seeded file"; pass=$((pass + 1))
else
    echo "FAIL the extra-env -e flag does not follow --env-file on the command line"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
fi
if grep -q 'DAST extra-env: applied 1 override(s)\.' "$WORK/log" && ! grep -q 'override-value' "$WORK/log"; then
    echo "ok   the override count is logged, its value is not"; pass=$((pass + 1))
else
    echo "FAIL the override count is missing, or the value leaked into the log"
    sed 's/^/     /' "$WORK/log"
    fail=$((fail + 1))
fi

DAST_EXTRA_ENV="KEY=a=b=c" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "a value containing = survives intact" clean 0
if grep -qE -- '-e KEY=a=b=c( |$)' "$WORK/dockerlog"; then
    echo "ok   a value containing = is passed through verbatim"; pass=$((pass + 1))
else
    echo "FAIL a value containing = was mangled or missing"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
fi

DAST_EXTRA_ENV=$'\n\n   S3_ENDPOINT=https://s3.example.com\n\n' \
    SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "blank lines in extra-env are skipped" clean 0
extra_env_hits=$(grep -oE -- '-e S3_ENDPOINT=https://s3\.example\.com' "$WORK/dockerlog" | wc -l | tr -d ' ' || true)
if [ "$extra_env_hits" = "1" ]; then
    echo "ok   blank lines produce no extra -e flags, only the real line survives"; pass=$((pass + 1))
else
    echo "FAIL expected exactly one -e S3_ENDPOINT flag, found $extra_env_hits"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
fi

# Baseline captured with no extra-env at all, then proven byte-for-byte identical to a
# run with DAST_EXTRA_ENV explicitly set to empty — the input must be a strict no-op
# when unset, exactly as every arm of Resolve DAST target that has nothing to override.
unset DAST_EXTRA_ENV
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "baseline nova-app invocation with no extra-env" clean 0
without_extra_env=$(grep -E '^run .*--name nova-app' "$WORK/dockerlog")

DAST_EXTRA_ENV="" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "empty extra-env changes nothing about the command line" clean 0
with_empty_extra_env=$(grep -E '^run .*--name nova-app' "$WORK/dockerlog")
if [ "$without_extra_env" = "$with_empty_extra_env" ] && [ -n "$without_extra_env" ]; then
    echo "ok   empty extra-env leaves the nova-app command line unchanged"; pass=$((pass + 1))
else
    echo "FAIL empty extra-env altered the nova-app command line"
    echo "     before: $without_extra_env"
    echo "     after:  $with_empty_extra_env"
    fail=$((fail + 1))
fi


# novatalks.dialer's boot log read "Error: connect ECONNREFUSED ::1:4222" — the engine
# reaches NestJS startup but dies because nothing is listening on NATS's port. needs-nats
# brings up a bare, unconfigured NATS server (no config file, no auth, no TLS, no
# JetStream) the same way needs-db brings up postgres/redis, gated on its own flag so the
# other eight repositories, which never asked for NATS, never pay for it.
DAST_NEEDS_NATS=true SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "needs-nats true starts a nova-nats container" clean 0
if grep -qE -- '^run .*--name nova-nats\b' "$WORK/dockerlog"; then
    echo "ok   a nova-nats container is started when needs-nats is true"; pass=$((pass + 1))
else
    echo "FAIL no nova-nats container appeared in the docker log"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
fi

# JetStream, not plain NATS. The dialer's client calls $JS.API.INFO during startup,
# and a server without -js answers 503 (no responders), which reads in the app log as
# a missing peer service rather than a missing server feature — it cost a wrong
# diagnosis once. Production NATS runs JetStream too, so this matches it.
if grep -qE -- '^run .*--name nova-nats\b.* -js( |$)' "$WORK/dockerlog"; then
    echo "ok   the nova-nats container enables JetStream"; pass=$((pass + 1))
else
    echo "FAIL nova-nats started without -js; \$JS.API.INFO would answer 503"; fail=$((fail + 1))
fi

# JetStream running is not the same as the stream existing: the dialer resolves a
# subject to a stream and throws "no stream matches subject" against an empty server.
if grep -qE -- 'stream add campaign' "$WORK/dockerlog" && grep -qE -- "subjects campaign" "$WORK/dockerlog"; then
    echo "ok   the campaign stream is created with its subjects"; pass=$((pass + 1))
else
    echo "FAIL no campaign stream was created; the dialer resolves a subject at startup"; fail=$((fail + 1))
fi
assert_cleanup "needs-nats run tears all four containers down"

DAST_NEEDS_NATS=false SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "needs-nats false starts no NATS container" clean 0
if grep -qE -- '^run .*--name nova-nats\b' "$WORK/dockerlog"; then
    echo "FAIL a nova-nats container was started despite needs-nats being false"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
else
    echo "ok   no nova-nats container appears in the docker log when needs-nats is false"; pass=$((pass + 1))
fi

# The client address is forced the same way PORT/APP_PORT are: "ECONNREFUSED ::1:4222"
# is IPv6 resolution of `localhost`, and a server bound to 0.0.0.0 still refuses that.
# Naming 127.0.0.1 explicitly removes the resolution question, and it must come after
# --env-file so it wins over anything a seeded .env.example named.
GITHUB_WORKSPACE="$WS_WITH_ENV" DAST_NEEDS_NATS=true SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "NATS_SERVERS is forced on the application container" clean 0
if grep -qE -- '--name nova-app.*--env-file [^ ]*dast\.env.*-e NATS_SERVERS=127\.0\.0\.1:4222( |$)' "$WORK/dockerlog"; then
    echo "ok   NATS_SERVERS=127.0.0.1:4222 is passed to the app container, after --env-file"; pass=$((pass + 1))
else
    echo "FAIL NATS_SERVERS missing, or not ahead of --env-file on the command line"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
fi

# NATS ready, but the application container itself refuses to start (SHIM_APP_RC, not a
# boot timeout) — nova-nats must still be torn down by the same EXIT trap. needs-db is
# turned off here so the shared "default run" exit code only has to account for
# nova-nats (its own dedicated shim branch) and nova-app, not also nova-pg/nova-redis.
DAST_NEEDS_NATS=true DAST_NEEDS_DB=false SHIM_CURL_RC=0 SHIM_APP_RC=1 \
    expect "nova-nats is torn down when the application fails to boot" not-run 0
if grep -qE -- '^run .*--name nova-nats\b' "$WORK/dockerlog"; then
    echo "ok   nova-nats had actually started before the app refused to boot"; pass=$((pass + 1))
else
    echo "FAIL nova-nats never started in this scenario — teardown assertion would be vacuous"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
fi
assert_cleanup "app-boot-failure run still tears nova-nats down alongside the rest"

# NATS itself never answers its monitoring port — this must land on the same loud-skip
# path as a postgres or app boot timeout, never `error` (NATS isn't the scanner) and
# never `clean` (an application that can't reach NATS never actually came up). The app's
# own health probe (SHIM_CURL_RC=0) would happily report booted if the run ever reached
# it — it must not, proving the NATS readiness check itself gates the run rather than
# merely coinciding with an app that was going to fail anyway.
DAST_NEEDS_NATS=true DAST_NEEDS_DB=false SHIM_NATS_CURL_RC=7 SHIM_CURL_RC=0 SHIM_NATS_RUN_RC=0 SHIM_ZAP_RC=0 \
    expect "a NATS that never becomes ready is a loud skip, not clean or error" not-run 0
assert_cleanup "unready-NATS run still tears containers down"

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
#
# The console carries a realistic per-rule FAIL-NEW line and per-rule WARN-NEW line
# ahead of the tally, exactly as print_rule (zap_common.py:205) actually emits them —
# not the tally alone, which real ZAP never produces on its own. A per-rule FAIL-NEW
# line starts with the same `FAIL-NEW: ` prefix as the tally, so this is also the
# regression fixture for the tally-line anchor: a `grep -m1 -E '^FAIL-NEW: '` with no
# further shape check would take the per-rule line instead of the tally.
SHIM_CURL_RC=0 SHIM_ZAP_RC=1 SHIM_ZAP_CONSOLE="FAIL-NEW: Some Critical Alert [90001] x 2
WARN-NEW: Some Warning Alert [10038] x 5
FAIL-NEW: 2	FAIL-INPROG: 0	WARN-NEW: 5	WARN-INPROG: 0	INFO: 1	IGNORE: 3	PASS: 30" \
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
# The reason is asserted, not just the outcome. Both tally guards end in scanner_error,
# so outcome+rc alone cannot tell them apart: with only that check, deleting the
# missing-tally guard still passed this scenario, because the numeric guard below caught
# the empty parse on the way past. Matching the reason makes each guard independently
# falsifiable.
if grep -q 'no result tally' "$WORK/output"; then
    echo "ok   a missing tally is reported as a missing tally, not as a malformed one"; pass=$((pass + 1))
else
    echo "FAIL the missing-tally guard did not name the missing tally"
    sed 's/^/     /' "$WORK/output"
    fail=$((fail + 1))
fi

# FAIL-NEW stays numeric so the anchor matches and this reaches the guard it is named
# for. The earlier fixture used `FAIL-NEW: none`, which the anchor's [0-9]+ rejects
# outright — it exited through the missing-tally guard above and never exercised the
# numeric one at all.
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: many	WARN-INPROG: 0	INFO: 0	IGNORE: 0	PASS: 40" \
    expect "a non-numeric tally is a scanner error" error 2
if grep -q 'malformed' "$WORK/output"; then
    echo "ok   a matched-but-unparseable tally is reported as malformed"; pass=$((pass + 1))
else
    echo "FAIL the numeric tally guard did not fire"
    sed 's/^/     /' "$WORK/output"
    fail=$((fail + 1))
fi

# Exit 3 is both "an exception was raised" and "nothing passed, warned or failed" — no
# rule ran at all. Both are broken gates.
SHIM_CURL_RC=0 SHIM_ZAP_RC=3 \
    expect "exit 3 stays a scanner error" error 2

# --- a postgres that never comes up says so, and says it about postgres ---------------
# This is the regression that hid for weeks. The image was
# ghcr.io/cloudnative-pg/postgresql — the CloudNativePG *operator* image, whose config is
# `Entrypoint: null`, `Cmd: ["bash"]`. Under `docker run -d` bash exits at once and the
# POSTGRES_* variables are read by nobody, but a container ID still comes back, so
# `|| not_run "postgres did not start"` never fired. pg_isready then failed for sixty
# seconds, the loop fell through in silence, and the application died with ECONNREFUSED —
# reported as "the image did not come up", blaming the image for a database that was
# never there. Every database-backed scan had been a loud skip since.
DAST_NEEDS_DB=true SHIM_PG_READY_RC=1 SHIM_CURL_RC=0 SHIM_ZAP_RC=0 \
    expect "a postgres that never becomes ready is a loud skip" not-run 0
if grep -q "postgres never became ready" "$WORK/report"; then
    echo "ok   the skip names postgres, not the application image"; pass=$((pass + 1))
else
    echo "FAIL the skip still blames the image for a database that never started"
    fail=$((fail + 1))
fi
if grep -q "docker logs nova-pg" "$WORK/log"; then
    echo "ok   and prints postgres's own output"; pass=$((pass + 1))
else
    echo "FAIL no postgres log — the skip is a dead end again"; fail=$((fail + 1))
fi

# The image must stay one whose entrypoint actually starts postgres. Asserting the
# Docker Official name is a blunt guard, and deliberately so: the failure it prevents is
# somebody reaching for a vendor image again, and the family is what distinguishes them.
DAST_NEEDS_DB=true SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "a database-backed scan runs" clean 0
if grep -E "^run .*--name nova-pg" "$WORK/dockerlog" | grep -qE " postgres:[0-9]"; then
    echo "ok   postgres comes from the Docker Official image"; pass=$((pass + 1))
else
    echo "FAIL nova-pg is not a postgres:N image — check it has an entrypoint that starts postgres"
    grep -E "^run .*--name nova-pg" "$WORK/dockerlog" | sed 's/^/     /'
    fail=$((fail + 1))
fi


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

# A context file teaches ZAP the login form. -n and -U must travel together: a context
# loaded with no user selected scans as nobody while looking configured, the same
# failure shape as the unquoted -z replacer in dast-api.
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
unset DAST_SCAN_MODE

# --- which repository is being scanned is an input, not an accident of who is running --
# Every caller until ci-dast-pentest.yaml was the reusable build workflow, which runs in
# the product repository's own context, so GITHUB_REPOSITORY happened to name the scanned
# repository. The pentest workflow runs in nova.ci. Two things keyed off that name and
# both were silently wrong there: the postgres major version, and whether the .env.example
# in GITHUB_WORKSPACE is this application's configuration at all.

assert_pg_image() { # assert_pg_image <name> <expected image>
    local got
    got="$(grep -E '^run .*--name nova-pg' "$WORK/dockerlog" | grep -oE 'postgres:[^ ]+' | head -1 || true)"
    if [ "$got" = "$2" ]; then
        echo "ok   $1"; pass=$((pass + 1))
    else
        echo "FAIL $1 — expected $2, got '${got:-none}'"; fail=$((fail + 1))
    fi
}

# The input set: the scanned repository is novatalks.core even though the job is running
# somewhere else entirely. This is the pentest case, and the one that was broken.
DAST_TARGET_REPO=novatalks.core GITHUB_REPOSITORY=novaitdevteam/nova.ci \
DAST_NEEDS_DB=true SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "target-repository set: the scan still runs" clean 0
assert_pg_image "target-repository picks novatalks.core's postgres, not the runner's" postgres:17.9-trixie
# The choice being right is half of it; the other half is that it is visible. It was made
# silently before, which is why getting it wrong went unnoticed.
if grep -q "DAST postgres: postgres:17.9-trixie — chosen for 'novatalks.core' (from the target-repository input)" "$WORK/log"; then
    echo "ok   the postgres choice and its source are logged"; pass=$((pass + 1))
else
    echo "FAIL the postgres choice is still silent"; fail=$((fail + 1))
fi
unset DAST_TARGET_REPO GITHUB_REPOSITORY

# The input unset: byte-identical to the behaviour every existing caller has today.
GITHUB_REPOSITORY=novaitdevteam/novatalks.core \
DAST_NEEDS_DB=true SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "target-repository unset: the scan still runs" clean 0
assert_pg_image "an unset input falls back to GITHUB_REPOSITORY" postgres:17.9-trixie
if grep -q "(from GITHUB_REPOSITORY)" "$WORK/log"; then
    echo "ok   the fallback names itself as the fallback"; pass=$((pass + 1))
else
    echo "FAIL the log does not say where the repository name came from"; fail=$((fail + 1))
fi
unset GITHUB_REPOSITORY

GITHUB_REPOSITORY=novaitdevteam/nova.botflow \
DAST_NEEDS_DB=true SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "every other repository still resolves through the fallback" clean 0
assert_pg_image "a non-core repository takes postgres:16" postgres:16
unset GITHUB_REPOSITORY

# The workspace is nova.ci's checkout, the scanned image is novatalks.core's. nova.ci has
# an .env.example of its own (outline/jira MCP keys). Seeding it would hand the engine
# four unrelated variables, log a plausible "seeded 4 variable(s)", and then blame the
# image for the boot it caused.
GITHUB_WORKSPACE="$WS_WITH_ENV" GITHUB_REPOSITORY=novaitdevteam/nova.ci \
DAST_TARGET_REPO=novatalks.core \
DAST_NEEDS_DB=true SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "a foreign workspace does not stop a scan that can still run" clean 0
if grep -qE '^run .*--env-file' "$WORK/dockerlog"; then
    echo "FAIL another repository's .env.example was seeded into the container"; fail=$((fail + 1))
else
    echo "ok   another repository's .env.example is not seeded"; pass=$((pass + 1))
fi
if grep -q '::warning::DAST env file: not seeded' "$WORK/log"; then
    echo "ok   and the skip says so rather than passing in silence"; pass=$((pass + 1))
else
    echo "FAIL the env file was skipped silently — indistinguishable from a repo with no .env.example"
    fail=$((fail + 1))
fi
unset GITHUB_WORKSPACE GITHUB_REPOSITORY DAST_TARGET_REPO

# ...and when the application then does not boot, the loud skip names our own missing
# input instead of blaming the image, which is the whole reason the warning above is a
# warning rather than a hard stop.
GITHUB_WORKSPACE="$WS_WITH_ENV" GITHUB_REPOSITORY=novaitdevteam/nova.ci \
DAST_TARGET_REPO=novatalks.core \
DAST_NEEDS_DB=true SHIM_CURL_RC=1 \
    expect "a boot failure after a skipped env file is a loud skip" not-run 0
if grep -q "no .env.example was seeded" "$WORK/report"; then
    echo "ok   the loud skip names the missing seed, not just the image"; pass=$((pass + 1))
else
    echo "FAIL the skip blames the image for configuration we withheld"
    sed 's/^/     /' "$WORK/report"
    fail=$((fail + 1))
fi
unset GITHUB_WORKSPACE GITHUB_REPOSITORY DAST_TARGET_REPO

# The build workflow's own shape: the input is set and it agrees with GITHUB_REPOSITORY,
# so the workspace really is the scanned repository's checkout and seeding proceeds
# exactly as it always has.
GITHUB_WORKSPACE="$WS_WITH_ENV" GITHUB_REPOSITORY=novaitdevteam/novatalks.core \
DAST_TARGET_REPO=novatalks.core \
DAST_NEEDS_DB=true SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZAP_CLEAN_CONSOLE" \
    expect "the workspace's own .env.example is still seeded" clean 0
if grep -qE '^run .*--env-file' "$WORK/dockerlog"; then
    echo "ok   a matching workspace seeds as before"; pass=$((pass + 1))
else
    echo "FAIL the new gate broke seeding for the caller it must not change"; fail=$((fail + 1))
fi
unset GITHUB_WORKSPACE GITHUB_REPOSITORY DAST_TARGET_REPO

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
