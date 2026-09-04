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

# novatalks.ui, browser surface: DT_ZAP_CONTEXT stays empty. A context file exists
# (contexts/novatalks-ui.context) with the verified login request shape, but this arm
# boots no backend to log into (nginx serving static files, no API base URL configured
# anywhere) — confirmed both in source and live against the published image (POST
# /auth/sign_in returns 405; every route returns the byte-identical static shell). Set
# it and this check must be updated deliberately, alongside the arm's own comment.
reset_dt; dast_resolve_target novatalks.ui browser
check "ui/browser port"          8000     "$DT_PORT"
check "ui/browser has no context yet" "" "$DT_ZAP_CONTEXT"

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

# whatsapp: db-insert (its Dockerfile ships no npm at runtime, but the seeder survives
# as compiled JS the entrypoint already runs — see the arm's own comment). Header and
# schema read from roles.guard.ts / token.model.ts / token-role.model.ts.
reset_dt; dast_resolve_target nova.chatsconnector.whatsapp-client-api api
check "whatsapp auth mode"       db-insert          "$DT_AUTH_MODE"
check "whatsapp header"          api_access_token   "$DT_AUTH_HEADER"
check "whatsapp prefix"          ""                 "$DT_AUTH_SCHEME_PREFIX"
check "whatsapp health path"     /health            "$DT_HEALTH_PATH"
check "whatsapp spec path"       /api-docs-json     "$DT_SPEC_PATH"
check "whatsapp setup command"   ""                 "$DT_SETUP_COMMAND"
if [ -n "$DT_TOKEN_INSERT_SQL" ]; then
    echo "ok   whatsapp carries an INSERT"; pass=$((pass + 1))
else
    echo "FAIL whatsapp has no INSERT — db-insert would loud-skip"; fail=$((fail + 1))
fi
# The role value is 'super_admin' (token-role.enum.ts) — lowercase, unlike the telegram
# connector's 'SUPER_ADMIN'. A guessed uppercase value would insert a token nothing can
# join to, silently.
case "$DT_TOKEN_INSERT_SQL" in
    *"'super_admin'"*) echo "ok   whatsapp INSERT targets the lowercase role value"; pass=$((pass + 1)) ;;
    *) echo "FAIL whatsapp INSERT does not reference the real 'super_admin' role value"; fail=$((fail + 1)) ;;
esac

# signal: expected to match whatsapp, verified independently rather than copied. It does
# NOT match on two points — no health controller at all (so "/", like telegram/botflow),
# and a Joi env-validation schema (env.validation.ts) that requires five storage/S3 vars
# non-blank, which whatsapp has no equivalent of.
reset_dt; dast_resolve_target nova.chatsconnector.signal-client-api api
check "signal auth mode"       db-insert          "$DT_AUTH_MODE"
check "signal header"          api_access_token   "$DT_AUTH_HEADER"
check "signal prefix"          ""                 "$DT_AUTH_SCHEME_PREFIX"
check "signal health path"     /                  "$DT_HEALTH_PATH"
check "signal spec path"       /api-docs-json     "$DT_SPEC_PATH"
if [ -n "$DT_TOKEN_INSERT_SQL" ]; then
    echo "ok   signal carries an INSERT"; pass=$((pass + 1))
else
    echo "FAIL signal has no INSERT — db-insert would loud-skip"; fail=$((fail + 1))
fi
for var in STORAGE_PATH S3_ENDPOINT S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_BUCKET; do
    case "$DT_EXTRA_ENV" in
        *"$var="*) echo "ok   signal extra-env carries $var"; pass=$((pass + 1)) ;;
        *) echo "FAIL signal extra-env is missing $var — env.validation.ts rejects it blank"; fail=$((fail + 1)) ;;
    esac
done

# novatalks.dialer: env-token, confirmed in auth.middleware.ts/app.config.ts. Its Joi
# schema itself never rejects a blank var (every field has a default), but
# nats.config.ts's registerAs factory calls NATS_SUBJECTS.split(',') unconditionally at
# config-load time — a missing NATS_SUBJECTS throws before app.listen() regardless of
# whether a NATS server is reachable.
reset_dt; dast_resolve_target novatalks.dialer api
check "dialer auth mode"      env-token               "$DT_AUTH_MODE"
check "dialer header"         api_access_token        "$DT_AUTH_HEADER"
check "dialer prefix"         ""                      "$DT_AUTH_SCHEME_PREFIX"
check "dialer token env var"  API_ACCESS_TOKENS       "$DT_TOKEN_ENV_VAR"
check "dialer port"           3000                    "$DT_PORT"
check "dialer health path"    /readyz                 "$DT_HEALTH_PATH"
check "dialer spec path"      /api/v1/dialer/api-docs-json "$DT_SPEC_PATH"
check "dialer needs nats"     true                    "$DT_NEEDS_NATS"
case "$DT_EXTRA_ENV" in
    *"NATS_SUBJECTS="*) echo "ok   dialer extra-env carries NATS_SUBJECTS"; pass=$((pass + 1)) ;;
    *) echo "FAIL dialer extra-env is missing NATS_SUBJECTS — nats.config.ts would crash on boot"; fail=$((fail + 1)) ;;
esac

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
