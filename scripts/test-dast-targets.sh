#!/usr/bin/env bash
#
# Self-check for .github/actions/dast/targets.sh — the single per-repository DAST table.
#
# The table decides where every scanner points and how it authenticates. A wrong value
# here is not a crash: it is a scan of the wrong port that finds nothing and reports it
# clean. So the shape of every arm is asserted, and the default arm is asserted to fail.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../.github/actions/dast/targets.sh
. "$ROOT/.github/actions/dast/targets.sh"

pass=0
fail=0

check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "ok   $1"; pass=$((pass + 1))
    else
        echo "FAIL $1 — expected '$2', got '$3'"; fail=$((fail + 1))
    fi
}

reset_dt() { unset "${!DT_@}"; }

# novatalks.core, browser surface: the values the build workflow has always used.
reset_dt; dast_resolve_target novatalks.core browser
check "core/browser port"        3000     "$DT_PORT"
check "core/browser health"      /livez   "$DT_HEALTH_PATH"
check "core/browser needs a db"  true     "$DT_NEEDS_DB"

# novatalks.core, api surface: same image, different scanner, JWT login.
reset_dt; dast_resolve_target novatalks.core api
check "core/api auth mode"       login              "$DT_AUTH_MODE"
check "core/api login path"      /auth/sign_in      "$DT_LOGIN_PATH"
check "core/api header"          Authorization      "$DT_AUTH_HEADER"
check "core/api prefix"          "Bearer "          "$DT_AUTH_SCHEME_PREFIX"
check "core/api spec path"       /api-docs-json     "$DT_SPEC_PATH"
# Empty on purpose: the runtime image ships no npm and its entrypoint migrates and seeds.
check "core/api setup command"   ""                 "$DT_SETUP_COMMAND"

# The telegram connector: a DB-backed token under its own header, no scheme prefix.
reset_dt; dast_resolve_target nova.chatsconnector.telegram-client-api api
check "telegram auth mode"       db-token           "$DT_AUTH_MODE"
check "telegram header"          api_access_token   "$DT_AUTH_HEADER"
check "telegram prefix is empty" ""                 "$DT_AUTH_SCHEME_PREFIX"
check "telegram health path"     /                  "$DT_HEALTH_PATH"

# nova.botflow has no HTTP health route; "/" is correct and must not be "fixed".
reset_dt; dast_resolve_target nova.botflow browser
check "botflow port"             1880     "$DT_PORT"
check "botflow health"           /        "$DT_HEALTH_PATH"

# A guessed target scans the wrong port and reports it clean, so an unknown pair must
# fail loudly rather than fall through to a default.
reset_dt
if dast_resolve_target no.such.repo api >/dev/null 2>&1; then
    echo "FAIL an unknown repository resolved instead of failing"; fail=$((fail + 1))
else
    echo "ok   an unknown repository fails loudly"; pass=$((pass + 1))
fi

# A repository with no browser surface must not silently answer for one.
reset_dt
if dast_resolve_target nova.chatsconnector.telegram-client-api browser >/dev/null 2>&1; then
    echo "FAIL a headless connector resolved a browser surface"; fail=$((fail + 1))
else
    echo "ok   a headless connector has no browser surface"; pass=$((pass + 1))
fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
