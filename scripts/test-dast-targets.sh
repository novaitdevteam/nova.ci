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
# Run 33863826945: MulterConfigService.createMulterOptions() getOrThrow()s these five
# file.awsS3* keys at module registration, unconditionally, since dast-api/scan.sh seeds
# no .env.example. Obviously-fake values, never a plausible-looking one — this
# repository is public.
for var in AWS_S3_ACCESS_KEY_ID AWS_S3_SECRET_ACCESS_KEY AWS_S3_BUCKET AWS_S3_REGION AWS_S3_ENDPOINT; do
    case "$DT_EXTRA_ENV" in
        *"$var="*) echo "ok   core/api extra-env carries $var"; pass=$((pass + 1)) ;;
        *) echo "FAIL core/api extra-env is missing $var — MulterConfigService.getOrThrow() would crash on boot"; fail=$((fail + 1)) ;;
    esac
done
case "$DT_EXTRA_ENV" in
    *"AWS_S3_ACCESS_KEY_ID=dast-dummy"*|*"AWS_S3_SECRET_ACCESS_KEY=dast-dummy"*)
        echo "ok   core/api's AWS_S3 values are obviously fake, not plausible-looking"; pass=$((pass + 1)) ;;
    *) echo "FAIL core/api's AWS_S3 values do not look like dummies"; fail=$((fail + 1)) ;;
esac

# The telegram connector: a DB-backed token under its own header, no scheme prefix.
reset_dt; dast_resolve_target nova.chatsconnector.telegram-client-api api
check "telegram auth mode"       db-token           "$DT_AUTH_MODE"
check "telegram header"          api_access_token   "$DT_AUTH_HEADER"
check "telegram prefix is empty" ""                 "$DT_AUTH_SCHEME_PREFIX"
check "telegram health path"     /                  "$DT_HEALTH_PATH"
# WEBHOOK_URL: required by the Joi validationSchema in src/app.module.ts at the exact
# commit (9a879f10) the failing live run was built from — three commits behind current
# master, which dropped it. Kept as a dummy in case an older tag is scanned again.
for var in TELEGRAM_API_ID TELEGRAM_API_HASH NOVATALKS_ACCESS_TOKEN ENCRYPTION_SECRET WEBHOOK_URL; do
    case "$DT_EXTRA_ENV" in
        *"$var="*) echo "ok   telegram extra-env carries $var"; pass=$((pass + 1)) ;;
        *) echo "FAIL telegram extra-env is missing $var — the config validator would crash on boot"; fail=$((fail + 1)) ;;
    esac
done

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
# NATS_DELIVER_TO: the app creates its own push consumer (nats-config.service.ts's
# consumerOptions), and nats' jsclient.js:365 throws "push consumer requires
# deliver_subject" when this is absent — confirmed live on run 33873579035.
# NATS_DELIVER_GROUP/NATS_DURABLE are deliberately not required here: both feed
# no-op opts.*() calls when unset, so omitting them yields a plain ephemeral
# consumer, not a crash.
case "$DT_EXTRA_ENV" in
    *"NATS_DELIVER_TO="*) echo "ok   dialer extra-env carries NATS_DELIVER_TO"; pass=$((pass + 1)) ;;
    *) echo "FAIL dialer extra-env is missing NATS_DELIVER_TO — the consumer create would crash boot (run 33873579035)"; fail=$((fail + 1)) ;;
esac
# The consumer's deliver subject must stay outside the stream's own subject space
# (NATS_SUBJECTS=campaign.*) or the consumer feeds the stream it reads from.
case "$DT_EXTRA_ENV" in
    *"NATS_DELIVER_TO=campaign."*) echo "FAIL dialer NATS_DELIVER_TO collides with the stream's own campaign.* subjects"; fail=$((fail + 1)) ;;
    *) echo "ok   dialer NATS_DELIVER_TO does not collide with campaign.*"; pass=$((pass + 1)) ;;
esac
# HEALTH_ENABLED: src/app.module.ts only imports HealthModule when this is 'true',
# checked directly against process.env before any ConfigService exists — without it
# /readyz (DT_HEALTH_PATH above) 404s for the container's whole life.
case "$DT_EXTRA_ENV" in
    *"HEALTH_ENABLED=true"*) echo "ok   dialer extra-env enables HealthModule"; pass=$((pass + 1)) ;;
    *) echo "FAIL dialer extra-env does not set HEALTH_ENABLED=true — /readyz would 404 forever"; fail=$((fail + 1)) ;;
esac
# AWS_S3_*: MulterConfigService (registered by ContactModule/DncListModule, both
# unconditional imports) builds multer-s3 storage at module-init time; multer-s3's own
# constructor throws "bucket is required" the instant file.awsS3Bucket is undefined.
for var in AWS_S3_ACCESS_KEY_ID AWS_S3_SECRET_ACCESS_KEY AWS_S3_BUCKET AWS_S3_REGION AWS_S3_ENDPOINT; do
    case "$DT_EXTRA_ENV" in
        *"$var="*) echo "ok   dialer extra-env carries $var"; pass=$((pass + 1)) ;;
        *) echo "FAIL dialer extra-env is missing $var — multer-s3 would crash on boot"; fail=$((fail + 1)) ;;
    esac
done

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

# --- the table's consumers: a value nobody reads is the same as a scan nobody ran -----
# DT_ZAP_CONTEXT was set by the table, declared as an input on dast/action.yml and
# honoured by dast/scan.sh — and no resolve step bridged the two. Setting it on an arm,
# updating this file, and watching everything pass would still have produced an anonymous
# crawl with no signal anywhere. ci-dast-pentest.yaml's resolve step is the one consumer
# that promises to emit EVERY key (it serves both surfaces), so that promise is what gets
# asserted, for every field rather than only for the one that was missed.
PENTEST="$ROOT/.github/workflows/ci-dast-pentest.yaml"
TARGETS="$ROOT/.github/actions/dast/targets.sh"

missing=""
for v in $(grep -oE 'DT_[A-Z_]+' "$TARGETS" | sort -u); do
    grep -qE "\\\$${v}\\b" "$PENTEST" || missing="$missing $v"
done
if [ -z "$missing" ]; then
    echo "ok   every DT_* the table sets is emitted by ci-dast-pentest.yaml's resolve step"
    pass=$((pass + 1))
else
    echo "FAIL ci-dast-pentest.yaml's resolve step never reads:$missing — the table can set them and nothing happens"
    fail=$((fail + 1))
fi

# The other half: a key emitted into $GITHUB_OUTPUT that no scan step passes on is
# equally inert. Both directions have to hold or the bridge has a hole at one end.
unread=""
for k in $(grep -oE '^ +echo "[a-z_]+(=|<<)' "$PENTEST" | grep -oE '"[a-z_]+' | tr -d '"' | sort -u); do
    # Two keys belong to other steps, not the resolve step: `host` (the live-target
    # allowlist) and `message` (the live scan's verdict). Both are read through their own
    # step ids, so steps.target.outputs is the wrong place to look for them.
    case "$k" in host|message) continue ;; esac
    grep -q "steps.target.outputs.${k}" "$PENTEST" || unread="$unread $k"
done
if [ -z "$unread" ]; then
    echo "ok   every key that step emits is passed on to a scan step"; pass=$((pass + 1))
else
    echo "FAIL ci-dast-pentest.yaml emits but never uses:$unread"; fail=$((fail + 1))
fi

# Named explicitly as well as covered by the loop above, because this is the one that
# was actually broken and the loop's message is generic.
if grep -q 'zap-context: ${{ steps.target.outputs.zap_context }}' "$PENTEST"; then
    echo "ok   DT_ZAP_CONTEXT reaches the browser scan step"; pass=$((pass + 1))
else
    echo "FAIL nothing passes zap-context — setting it on an arm would do nothing"
    fail=$((fail + 1))
fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
