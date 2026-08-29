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

pass=0
fail=0

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
                printf '%s\n' "${SHIM_ZAP_CONSOLE:-PASS: everything}"
                exit "${SHIM_ZAP_RC:-0}" ;;
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
    DAST_PG_IMAGE="postgres:16" \
    DAST_ENV_FILE="${DAST_ENV_FILE:-.env.example}" \
    DAST_EXTRA_ENV="${DAST_EXTRA_ENV:-}" \
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

SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: everything" \
    expect "app boots, ZAP finds nothing" clean 0
assert_cleanup "clean run tears containers down"
assert_findings "a console with no WARN-NEW line counts zero" 0
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
FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 3	WARN-INPROG: 0	INFO: 0	IGNORE: 0	PASS: 40" \
    expect "ZAP warnings are findings, not failure" findings 0
# Three per-rule lines, not four: the trailing tally line mentions WARN-NEW too but
# starts with FAIL-NEW:, which is why the count anchors on `^WARN-NEW: `.
assert_findings "only the per-rule WARN-NEW lines are counted, not the tally line" 3
assert_cleanup "findings run tears containers down"

# The regression this whole rewiring exists for. zap-baseline.py -w writes the
# traditional markdown report, which names alerts but never prints WARN-NEW; the
# WARN-NEW lines are on stdout only. Counting the -w file therefore yields a permanent
# zero — every run "🟢 clean", including one with twenty warnings. The md fixture below
# is deliberately full of alert text and free of WARN-NEW: a scan.sh that counts the
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
WARN-NEW: X-Content-Type-Options Header Missing [10021] x 6" \
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
DAST_NEEDS_DB=false SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: nothing to see" \
    expect "no-database app still boots and scans clean" clean 0
assert_cleanup "no-db run still tears containers down"
assert_no_db_containers "no-db run never starts postgres or redis"

# novatalks.core's production path: FILE_DRIVER=s3 and friends live in .env.example,
# not in this repo, so they must reach the app container without ever being typed here.
GITHUB_WORKSPACE="$WS_WITH_ENV" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: everything" \
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

GITHUB_WORKSPACE="$WS_WITHOUT_ENV" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: everything" \
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
GITHUB_WORKSPACE="$WS_WITH_ENV" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: everything" \
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
GITHUB_WORKSPACE="$WS_ALL_FILTERED" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: everything" \
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
GITHUB_WORKSPACE="$WS_TRAILING_COMMENT" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: everything" \
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
if grep -q 'seeded 2 variable(s); dropped 2 line(s) with a trailing comment, 1 NODE_ENV line(s)' "$WORK/log"; then
    echo "ok   seeded/dropped counts are logged, by rule"; pass=$((pass + 1))
else
    echo "FAIL seeded/dropped counts are missing from the output"
    sed 's/^/     /' "$WORK/log"
    fail=$((fail + 1))
fi

# Defect regression #1: nova.chatsconnector.telegram-client-api's .env.example carries
# DATABASE_URL="postgresql://user:!1q2w3e@localhost:5432/novatalks...". Docker's
# --env-file does not strip quotes the way dotenv does, so the container received a
# value whose first character is '"', and Prisma refused it outright — the engine never
# booted. Strip a matching pair of surrounding quotes only, nothing else.
GITHUB_WORKSPACE="$WS_QUOTED" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: everything" \
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

# Defect regression #2: even with quotes stripped, .env.example's own DATABASE_URL names
# a different user/password/database than the postgres this script actually starts (it
# documents a developer's local setup, not this scan run). Prisma-based repositories
# have no discrete DATABASE_* vars to bind to, so an explicit DATABASE_URL — built from
# the very same values used for the discrete vars and for the postgres container this
# script starts — must reach the app container and win over whatever the example said.
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: everything" \
    expect "DATABASE_URL is passed to the app container when the database is up" clean 0
if grep -qE -- '--name nova-app.*-e DATABASE_URL=postgresql://postgres:password@127\.0\.0\.1:5432/db_name( |$)' "$WORK/dockerlog"; then
    echo "ok   DATABASE_URL matches the user/password/db/port of the postgres this script started"; pass=$((pass + 1))
else
    echo "FAIL DATABASE_URL missing, or does not match the started postgres"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
fi

DAST_NEEDS_DB=false SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: nothing to see" \
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
    SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: everything" \
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

DAST_EXTRA_ENV="KEY=a=b=c" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: everything" \
    expect "a value containing = survives intact" clean 0
if grep -qE -- '-e KEY=a=b=c( |$)' "$WORK/dockerlog"; then
    echo "ok   a value containing = is passed through verbatim"; pass=$((pass + 1))
else
    echo "FAIL a value containing = was mangled or missing"
    sed 's/^/     /' "$WORK/dockerlog"
    fail=$((fail + 1))
fi

DAST_EXTRA_ENV=$'\n\n   S3_ENDPOINT=https://s3.example.com\n\n' \
    SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: everything" \
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
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: everything" \
    expect "baseline nova-app invocation with no extra-env" clean 0
without_extra_env=$(grep -E '^run .*--name nova-app' "$WORK/dockerlog")

DAST_EXTRA_ENV="" SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="PASS: everything" \
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

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
