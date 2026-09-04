#!/usr/bin/env bash
#
# Boot an application against ephemeral postgres and redis (and, when needs-nats is set,
# a NATS server — novatalks.dialer), run its own migrations and seed, acquire an auth
# token, and run zap-api-scan.py in safe mode against the app's own OpenAPI spec.
# Reports one of the same four outcomes as the baseline DAST scan — clean, findings,
# not-run, error — for the same reason: a boot, migration, seed or auth failure produces
# the same empty result a clean scan would, and reporting that as clean is the failure
# this job exists to avoid.
#
# Four auth-modes, selected by DAST_AUTH_MODE: `login` POSTs a username/password and
# reads the token from the response (novatalks.core's engine); `db-token` reads a token
# straight out of the seeded database with a caller-supplied SELECT (a connector with a
# DB-backed token in a header of its own name); `db-insert` writes its own token into the
# seeded database with a caller-supplied INSERT rather than depending on whatever key the
# image's own seeder happened to write (whatsapp, signal — their entrypoints DO self-seed,
# via compiled JS, but the token they produce is theirs, not ours); `env-token` generates a token before
# the container ever starts and hands it in as an environment variable, for an app that
# accepts any token present in a var it reads at boot (novatalks.dialer) — no database,
# no seed, no call to the engine at all. All four end with a bare token in $TOKEN,
# re-applied with the caller's own DAST_AUTH_HEADER/DAST_AUTH_PREFIX at injection.
#
# Zero secrets stored: the database is ours and dies with this job, so the admin
# password is generated here and used once to log in. The token reaches ZAP as a
# replacer rule on the docker command line, and ZAP echoes that replacer config — token
# included — back on its own stdout. This repo is public, so that stdout is a
# world-readable, GitHub-persisted step log the instant it is written; deleting a local
# file cannot undo that. The token is masked from the log with `::add-mask::` as soon as
# it is acquired (see below), and the console file that carries it is still deleted
# in the trap — belt and suspenders, not full containment on the file alone.
#
# Safe mode (-S) is the default: without it, zap-api-scan.py actively scans, i.e. sends
# real POST/PUT/DELETE against the seeded API using the very session this script just
# created. scan-mode: active drops -S deliberately — see the DAST_API_SCAN_MODE case
# above the docker run below. -f openapi drives the scan from the spec's real routes
# rather than a spider — a NestJS SPA-less API has no pages to spider in the first place.
#
set -euo pipefail

: "${DAST_IMAGE:?}" "${ZAP_IMAGE:?}" "${DAST_REPORT_FILE:?}" "${DAST_ACTION_ROOT:?}"

# shellcheck source=.github/actions/dast/dast-common.sh
. "${DAST_ACTION_ROOT}/../dast/dast-common.sh"

# Path/URL variables and every helper down to scanner_error live above the generated
# secrets below, on purpose: env-token mode has to be able to call scanner_error before
# the application container exists (see below), and scanner_error's own call chain
# (summary -> spec_url, cleanup's EXIT trap -> zap_console/spec_file) needs all of these
# already bound under `set -u`, not filled in later by code that runs after it.
DAST_BOOT_TIMEOUT="${DAST_BOOT_TIMEOUT:-300}"
# Port and routes are inputs (see action.yml), each defaulted to the value
# novatalks.core's engine has always used, so an unconfigured caller is byte-identical
# to before this action took connectors — see the "Resolve DAST target" case arm in
# ci-build-ntk-on-push-tags-build.yaml, which names the same port and health path for
# the baseline scan of the same image.
DAST_PORT="${DAST_PORT:-3000}"
DAST_NEEDS_NATS="${DAST_NEEDS_NATS:-false}"
# The repository whose image is being scanned — not necessarily the repository this job
# runs in. Every caller until now was the reusable build workflow, which runs in the
# product repository's own context, so GITHUB_REPOSITORY named the scanned repository by
# accident of who called. ci-dast-pentest.yaml runs in nova.ci and scans somebody else's
# image, and the postgres major version below keys off this name. The input wins when
# set; the fallback reproduces every pre-existing caller byte for byte.
DAST_TARGET_REPO="${DAST_TARGET_REPO:-}"
# GITHUB_REPOSITORY is always set on a real Actions run; the :- default here only
# keeps `set -u` from aborting when a developer runs this script (or the harness)
# locally without it — the stripped value is identical either way. The nested
# ${GITHUB_REPOSITORY##*/} inside a ${DAST_TARGET_REPO:-...} default still evaluates
# the inner expansion eagerly, so it needs the same guard.
github_repository="${GITHUB_REPOSITORY:-}"
scanned_repo="${DAST_TARGET_REPO:-${github_repository##*/}}"
if [ -n "$DAST_TARGET_REPO" ]; then
    repo_source="the target-repository input"
else
    repo_source="GITHUB_REPOSITORY"
fi
target="http://127.0.0.1:${DAST_PORT}"
health_url="${target}${DAST_HEALTH_PATH:-/livez}"
spec_url="${target}${DAST_SPEC_PATH:-/api-docs-json}"

zap_out="${RUNNER_TEMP:-/tmp}/zap-api.md"
zap_console="${RUNNER_TEMP:-/tmp}/zap-api-console.log"
# The triage register: which api-scan findings must be fixed, which are accepted, and
# why. Its own file, not the baseline's zap-baseline.conf — api-scan loads a different
# rule set (write-path checks the unauthenticated baseline never reaches), so the two
# registers are never interchangeable.
zap_conf_src="${DAST_ACTION_ROOT}/zap-api-scan.conf"
zap_conf="${RUNNER_TEMP:-/tmp}/zap-api-scan.conf"
spec_file="${RUNNER_TEMP:-/tmp}/dast-api-spec.json"
# Printed on failure, never suppressed, same reasoning as dast/scan.sh's own copy of
# this path: a stream that cannot be created must say why.
nats_stream_log="${RUNNER_TEMP:-/tmp}/nats-stream.log"

emit() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }

emit_message() {
    {
        echo "message<<DAST_API_EOF"
        printf '%s\n' "$1"
        echo "DAST_API_EOF"
    } >> "${GITHUB_OUTPUT:-/dev/null}"
}

cleanup() {
    docker rm -f nova-app nova-pg nova-redis nova-nats >/dev/null 2>&1 || true
    # The console log carries the token in ZAP's own replacer echo — already masked out
    # of the step log by ::add-mask:: below, but the local copy still doesn't belong on a
    # pooled, reused runner past this process's own lifetime. The spec file is a scratch
    # copy of a public route; same reasoning, lower stakes. The NATS stream-creation log
    # is the same idea as the zap console — printed on failure, never left behind.
    rm -f "$zap_console" "$spec_file" "$nats_stream_log" >/dev/null 2>&1 || true
}
trap cleanup EXIT

summary() { # summary <alert> <headline>
    {
        echo "## 🕷 DAST (ZAP API scan)"
        echo ""
        echo "> [!$1]"
        echo "> $2"
        echo ""
        echo "- Image: \`${DAST_IMAGE}\`"
        echo "- Spec: \`${spec_url}\`"
        echo "- Report: ${REPORT_URL:-not published}"
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

# Container output is the only evidence behind a boot or setup failure, and a loud skip
# without it is a dead end. Capped so a crash loop cannot bury the rest of the log.
dump_app_log() { # dump_app_log <why>
    echo "--- docker logs nova-app (${1}), last 60 lines ---"
    docker logs --tail 60 nova-app 2>&1 || echo "(no container output available)"
    echo "--- end ---"
}

not_run() { # not_run <reason>
    echo "::warning::DAST API scan did not run: $1"
    emit outcome not-run
    emit findings 0
    emit failures 0
    emit_message "🕷 DAST (ZAP API): ⚠️ not run — $1"
    summary WARNING "Scan did not run: $1. This is not a clean result."
    { echo "=== DAST API: not run ==="; echo "$1"; } > "$DAST_REPORT_FILE"
    exit 0
}

scanner_error() { # scanner_error <reason>
    echo "::error::DAST API scanner failed: $1"
    emit outcome error
    emit findings 0
    emit failures 0
    emit_message "🕷 DAST (ZAP API): ❌ scanner failed — $1"
    summary CAUTION "The scanner itself failed: $1. This is a broken gate."
    exit 2
}

# generated per run, never stored, never echoed
#
# The address has to be syntactically valid AND unable to ever resolve to a real
# mailbox — both halves matter and neither alone is enough. `@local` looked fine but
# is not a valid email: the engine's own entrypoint seeder validates it with Sequelize's
# `isEmail` (`require_tld: true`), `@local` has no top-level domain, the validator
# throws, the container dies mid-boot, and the job then loud-skips with "the image did
# not come up within 300s" — blaming the image for a bad input. Confirmed live on run
# 33761248644 against novatalks.core. `example.invalid` is RFC 2606 reserved: it passes
# `isEmail` and is guaranteed to never be a real, registrable domain.
ADMIN_USER="nova-ci-apiscan@example.invalid"
ADMIN_PASS="$(openssl rand -hex 24)"
# Masked before the application container exists, not just before ZAP runs. This script
# dumps container output when boot or setup fails — that is the only way to diagnose a
# loud skip — and a NestJS bootstrap that prints its resolved config would otherwise put
# this value straight into a world-readable step log. nova.ci is public.
echo "::add-mask::${ADMIN_PASS}"

# env-token acquires its token before the container exists, unlike every other mode,
# because the application reads it from its own environment. Generated and masked here so
# the order stays obvious: no mode may inject a value the runner has not been told to
# redact first.
ENV_TOKEN=""
if [ "${DAST_AUTH_MODE:-login}" = "env-token" ]; then
    [ -n "${DAST_TOKEN_ENV_VAR:-}" ] || scanner_error "env-token mode needs a token-env-var name"
    ENV_TOKEN="nova-ci-apiscan-$(openssl rand -hex 24)"
    echo "::add-mask::${ENV_TOKEN}"
fi

# Validated before anything is booted, same reasoning as the baseline: a broken register
# means ZAP silently applies a policy nobody wrote, and finding that out after a
# five-minute boot-and-seed helps nobody.
[ -r "$zap_conf_src" ] || scanner_error "the ZAP API triage register is missing or unreadable: ${zap_conf_src}"

conf_bad="$(awk -F'\t' '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    NF < 3 { printf "line %d: fewer than three tab-separated fields; ", NR; next }
    $2 != "PASS" && $2 != "IGNORE" && $2 != "INFO" && $2 != "WARN" && $2 != "FAIL" && $2 != "OUTOFSCOPE" {
        printf "line %d: unknown level \"%s\"; ", NR, $2 }
' "$zap_conf_src")"
[ -z "$conf_bad" ] || scanner_error "the ZAP API triage register is malformed — ${conf_bad}"
cp "$zap_conf_src" "$zap_conf"

# --- postgres and redis, identical shape to dast/scan.sh's needs-db block ------------
docker rm -f nova-pg nova-redis >/dev/null 2>&1 || true
# The Docker Official image, and the same expression the integration suite uses
# (ci-build-ntk-on-push-tags-run-test.yaml) — that postgres demonstrably works.
#
# It used to be ghcr.io/cloudnative-pg/postgresql:18.4-standard-trixie, which is the
# CloudNativePG *operator* image: its config is `Entrypoint: null`, `Cmd: ["bash"]`.
# Under `docker run -d` it starts bash, bash exits at once, and POSTGRES_PASSWORD /
# _USER / _DB are ignored entirely because there is no docker-entrypoint.sh to read
# them. `docker run -d` still returns a container ID, so `|| not_run` never fired.
# Every database-backed DAST scan had been a loud skip ever since — novatalks.core and
# nova.botflow for the baseline, every repository for api-scan. Only novatalks.ui,
# which sets needs-db false, was ever really scanned.
# novatalks.core mirrors the production PG major version; everything else takes 16 —
# the same split ci-build-ntk-on-push-tags-run-test.yaml makes, so the DAST stack and
# the integration stack cannot disagree about what database the app is talking to.
case "$scanned_repo" in
    novatalks.core) PG_IMAGE="${PG_IMAGE:-postgres:17.9-trixie}" ;;
    *)              PG_IMAGE="${PG_IMAGE:-postgres:16}" ;;
esac
# The choice used to be silent, which is how a pentest dispatch for novatalks.core could
# get postgres:16: the name it keys off came from the runner's repository, not the
# scanned one, and nothing said so. Name the image, the repository it was chosen for,
# and where that name came from.
echo "DAST API postgres: ${PG_IMAGE} — chosen for '${scanned_repo}' (from ${repo_source})."
docker run -d --name nova-pg -p 5432:5432 \
    -e POSTGRES_PASSWORD="${DATABASE_PASSWORD:-password}" \
    -e POSTGRES_USER="${DATABASE_USERNAME:-postgres}" \
    -e POSTGRES_DB="${DATABASE_NAME:-db_name}" \
    "$PG_IMAGE" \
    || not_run "postgres did not start"
docker run -d --name nova-redis -p 6379:6379 redis:8.6.4 || not_run "redis did not start"
pg_ready=no
for _ in $(seq 1 30); do
    if docker exec nova-pg pg_isready -U "${DATABASE_USERNAME:-postgres}" >/dev/null 2>&1; then
        pg_ready=yes
        break
    fi
    sleep 2
done
# The loop used to end here and fall straight through. That silence is exactly what let a
# postgres image with no entrypoint go unnoticed: the container "started", pg_isready
# failed for sixty seconds, the script carried on, and the application then died with
# ECONNREFUSED — reported as "the image did not come up", which blamed the image for a
# database that was never there. A wait that gives up has to say so.
if [ "$pg_ready" != yes ]; then
    echo "--- docker logs nova-pg (never became ready), last 40 lines ---"
    docker logs --tail 40 nova-pg 2>&1 || echo "(no output — the container may have exited at once)"
    echo "--- end ---"
    not_run "postgres never became ready in 60s — the application would fail with ECONNREFUSED"
fi
docker exec -e PGPASSWORD="${DATABASE_PASSWORD:-password}" nova-pg \
    psql -h 127.0.0.1 -U "${DATABASE_USERNAME:-postgres}" -d "${DATABASE_NAME:-db_name}" \
    -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;" >/dev/null 2>&1 || true

# --- NATS, only for a repository that needs it (novatalks.dialer) -------------------
# dast_bring_up_nats lives in dast-common.sh, shared with dast/scan.sh's identical
# needs-nats block, so the bring-up sequence exists in exactly one place. See that
# function's own comment for the js-init.sh cross-reference.
if [ "$DAST_NEEDS_NATS" = "true" ]; then
    dast_bring_up_nats not_run "$nats_stream_log"
fi

# --- the engine, seeded with the admin this run generates ----------------------------
# SWAGGER_ENABLE and NODE_ENV=production: without both, /api-docs-json comes back empty
# and step 6 below reports a loud skip rather than guessing a route exists. SWAGGER_ENABLE
# is gated on the swagger-enable input (default true, i.e. unchanged for core) — a
# connector may not have the var at all, and setting it there is harmless but dishonest.
# NODE_ENV=production stays unconditional: harmless for a connector, needed by core.
# DEFAULT_USER_PASSWORD reaches the container from the shell variable generated above,
# never typed as a literal anywhere — the action.yml that calls this script carries no
# credential at all.
app_env_args=()
[ "${DAST_SWAGGER_ENABLE:-true}" = "true" ] && app_env_args+=(-e SWAGGER_ENABLE=true)
# env-token: the token was generated before this container existed (see ENV_TOKEN
# above) — the application reads its accepted tokens from its own environment at boot,
# so this is the one auth-mode that hands the app anything before `docker run`. Written
# as an `if`, not `[ ... ] && app_env_args+=(...)`: the latter is the last command of
# this statement list under `set -e`, so a false test (every mode but env-token) would
# abort the whole script instead of just skipping the append.
if [ -n "$ENV_TOKEN" ]; then
    app_env_args+=(-e "${DAST_TOKEN_ENV_VAR}=${ENV_TOKEN}")
fi

# extra-env: a per-repository escape hatch, same shape as the baseline dast/scan.sh —
# one -e per non-empty line, never word-split, so a value containing spaces or `=`
# survives intact.
extra_env_args=()
if [ -n "${DAST_EXTRA_ENV:-}" ]; then
    while IFS= read -r extra_line || [ -n "$extra_line" ]; do
        trimmed="${extra_line#"${extra_line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        [ -z "$trimmed" ] && continue
        extra_env_args+=(-e "$trimmed")
    done <<< "$DAST_EXTRA_ENV"
fi

docker rm -f nova-app >/dev/null 2>&1 || true
docker run -d --name nova-app --network host \
    ${app_env_args[@]+"${app_env_args[@]}"} \
    -e NODE_ENV=production \
    ${extra_env_args[@]+"${extra_env_args[@]}"} \
    -e DEFAULT_ADMIN_USER="$ADMIN_USER" \
    -e DEFAULT_USER_PASSWORD="$ADMIN_PASS" \
    -e DATABASE_HOST=127.0.0.1 -e DATABASE_PORT=5432 \
    -e DATABASE_USERNAME="${DATABASE_USERNAME:-postgres}" \
    -e DATABASE_PASSWORD="${DATABASE_PASSWORD:-password}" \
    -e DATABASE_NAME="${DATABASE_NAME:-db_name}" \
    -e "DATABASE_URL=postgresql://${DATABASE_USERNAME:-postgres}:${DATABASE_PASSWORD:-password}@127.0.0.1:5432/${DATABASE_NAME:-db_name}" \
    -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6379 \
    -e PORT="$DAST_PORT" -e APP_PORT="$DAST_PORT" \
    -e NATS_SERVERS=127.0.0.1:4222 \
    "$DAST_IMAGE" || true
# NATS_SERVERS above is unconditional, same as DATABASE_HOST/PORT above it: a var an
# application never reads costs nothing, and dast/scan.sh sets it unconditionally too —
# novatalks.dialer's own boot log once read "Error: connect ECONNREFUSED ::1:4222"
# because the client resolved `localhost` to IPv6 and a NATS server bound to 0.0.0.0
# still refuses that connection; naming 127.0.0.1 explicitly removes the resolution
# question. Listed last so it wins over any same-named override in extra-env.

# `docker exec` against a container that never started fails on its own, so this used to
# cascade into the setup step's loud skip and report "database setup failed" for an image
# that had not started at all. Two very different causes behind one message is the defect
# this repository keeps legislating against — an alert that cannot tell them apart is one
# nobody acts on. Ask the container directly instead.
app_state="$(docker inspect -f '{{.State.Running}}' nova-app 2>/dev/null || echo missing)"
if [ "$app_state" != "true" ]; then
    dump_app_log "the container is not running"
    not_run "the image did not start — see the step log for its output"
fi

# create+migrate+seed, and only if the image cannot do it itself.
#
# Empty is the default and the common case, because both images wired up so far already
# run their own setup from their ENTRYPOINT before starting the app, reading the
# DEFAULT_ADMIN_USER/DEFAULT_USER_PASSWORD handed in above. Re-running it over `docker
# exec` was redundant at best and impossible at worst:
#
#   novatalks.core     the runtime stage installs nodejs-24 and *not* npm
#                      (docker/engine.Dockerfile), so `npm run db:setup:prod` could only
#                      ever answer `sh: npm: not found`. Its entrypoint.sh does the same
#                      three steps with plain `node` and says so in a comment.
#   telegram connector npm is present, but the exec raced the entrypoint doing the same
#                      work, and both failed on a missing DATABASE_URL — now set above.
#
# So: no command, no exec. The health poll below is the completion signal, because
# neither image serves anything until its entrypoint has finished migrating and seeding.
# A setup that fails there takes the container down with it, which the running-state
# check above already reports as a boot failure with the container's log attached.
#
# The escape hatch stays for an image that does not self-setup. Its output is captured
# rather than discarded: `>/dev/null 2>&1` made every failure here indistinguishable, and
# a loud skip nobody can act on is a dead end. ADMIN_PASS is masked above, so printing is
# safe.
if [ -n "${DAST_SETUP_CMD:-}" ]; then
    setup_log="${RUNNER_TEMP:-/tmp}/dast-api-setup.log"
    if ! docker exec nova-app sh -c "$DAST_SETUP_CMD" >"$setup_log" 2>&1; then
        echo "--- '${DAST_SETUP_CMD}' failed, last 60 lines ---"
        tail -60 "$setup_log" || true
        echo "--- end ---"
        dump_app_log "the setup command failed"
        not_run "database setup failed — see the step log for the command's output"
    fi
else
    echo "No setup-command: the image's entrypoint migrates and seeds before it serves."
fi

# --- boot ------------------------------------------------------------------------------
booted=no
attempts=$(( DAST_BOOT_TIMEOUT / 2 ))
[ "$attempts" -ge 1 ] || attempts=1
for _ in $(seq 1 "$attempts"); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "$health_url" || true)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then booted=yes; break; fi
    sleep 2
done

if [ "$booted" != "yes" ]; then
    docker logs --tail 40 nova-app 2>&1 | sed 's/^/    /' || true
    not_run "the image did not come up within ${DAST_BOOT_TIMEOUT}s"
fi

# --- acquire the auth token -------------------------------------------------------------
# login: -D - dumps headers to stdout, -o /dev/null discards the body — the token is read
# straight out of the captured header block and never touches a file or a log line. The
# password is used exactly once, right here. The bare token is stored (a leading `Bearer `
# is stripped if the response header carried one) so DAST_AUTH_PREFIX is applied
# uniformly at injection for both modes.
#
# db-token: the seeder already ran (above), so the token it wrote is read straight out
# of the database with the caller's own SELECT — robust against a seeder that never
# prints the token anywhere, and generalises past parsing console output.
#
# db-insert: whatsapp and signal run `npm prune --omit=dev`, which removes ts-node — but
# their entrypoints still migrate and seed themselves through the compiled JS in dist/,
# so a row probably does exist. It is not ours, though, and db-token would have to guess
# its shape and its role value out of a seeder we do not control. Writing our own row is
# the mode that does not depend on that: the INSERT either lands or loud-skips.
case "${DAST_AUTH_MODE:-login}" in
    login)
        login_headers="$(curl -s -D - -o /dev/null -X POST "${target}${DAST_LOGIN_PATH:-/auth/sign_in}" \
            -H 'Content-Type: application/json' \
            -H 'User-Agent: nova-ci-apiscan' \
            -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" 2>/dev/null || true)"

        # `|| true` on each extraction: with pipefail, grep finding no matching header
        # (the expected shape of a failed/no-token login) exits 1, and that would
        # otherwise propagate through the pipe and trip `set -e` before not_run ever
        # gets a chance to report it as the loud skip it is.
        TOKEN="$(printf '%s' "$login_headers" | tr -d '\r' \
            | grep -i '^authorization:' | head -1 \
            | sed -E 's/^[Aa]uthorization: *//' | sed -E 's/^[Bb]earer +//' || true)"
        if [ -z "$TOKEN" ]; then
            # Fallback for a cookie-session login rather than a bearer header.
            TOKEN="$(printf '%s' "$login_headers" | tr -d '\r' \
                | grep -i '^set-cookie:' | grep -i 'authentication=' | head -1 \
                | sed -E 's/.*[Aa]uthentication=([^;]*).*/\1/' || true)"
        fi
        ;;
    db-token)
        [ -n "${DAST_TOKEN_SQL:-}" ] || scanner_error "db-token mode needs a token-sql query"
        TOKEN="$(docker exec -e PGPASSWORD="${DATABASE_PASSWORD:-password}" nova-pg \
            psql -tAq -h 127.0.0.1 -U "${DATABASE_USERNAME:-postgres}" -d "${DATABASE_NAME:-db_name}" \
            -c "$DAST_TOKEN_SQL" 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
        ;;
    db-insert)
        # Produce our own token rather than depend on the image's. whatsapp and signal
        # DO self-seed — `npm prune --omit=dev` removes ts-node, but their entrypoints
        # run the compiled seeders in dist/ through plain `node` — so a token row very
        # likely exists; it is just not one we chose, and db-token would have to guess
        # its role value and column shape out of a seeder we do not own.
        #
        # The value is generated here and lives only in this job's database, which is
        # deleted with the container: nothing to store, nothing to rotate, nothing that
        # could be a real credential by accident.
        [ -n "${DAST_TOKEN_INSERT_SQL:-}" ] || scanner_error "db-insert mode needs a token-insert-sql statement"
        TOKEN="nova-ci-apiscan-$(openssl rand -hex 24)"
        # Masked here, before the value reaches a command line — not at the shared
        # ::add-mask:: below. The INSERT carries the token, and the failure path prints
        # psql's own output, which quotes the offending statement back. nova.ci is
        # public, so the mask has to exist before anything that could echo it does.
        echo "::add-mask::${TOKEN}"
        insert_sql="${DAST_TOKEN_INSERT_SQL//%TOKEN%/$TOKEN}"
        # Captured, not discarded. `>/dev/null 2>&1` left the loud skip guessing at one
        # cause out of several — the table may not exist, or the role_id subquery may
        # have matched no row, or the column names may have moved. psql says which.
        # ON_ERROR_STOP=1 so a SQL error is unambiguously a non-zero exit rather than
        # depending on psql's default per-mode behaviour: an INSERT that failed while
        # psql exited 0 is a token nothing accepts, scanned as if it were authenticated.
        insert_log="${RUNNER_TEMP:-/tmp}/dast-api-insert.log"
        if ! docker exec -e PGPASSWORD="${DATABASE_PASSWORD:-password}" nova-pg \
            psql -tAq -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "${DATABASE_USERNAME:-postgres}" -d "${DATABASE_NAME:-db_name}" \
            -c "$insert_sql" > "$insert_log" 2>&1; then
            echo "--- psql output (token INSERT failed) ---"
            sed 's/^/    /' "$insert_log" 2>/dev/null || true
            echo "--- end ---"
            rm -f "$insert_log" >/dev/null 2>&1 || true
            not_run "the token INSERT failed — the migration may not have created the table, or the role subquery matched no row; psql's own output is above"
        fi
        rm -f "$insert_log" >/dev/null 2>&1 || true
        ;;
    env-token)
        # Already generated above — it had to exist before the container did.
        TOKEN="$ENV_TOKEN"
        ;;
    *) scanner_error "unknown auth-mode: ${DAST_AUTH_MODE}" ;;
esac

# An empty token in either mode — login returned none, or the SELECT matched no row —
# is a loud skip, never a scan without auth.
[ -n "$TOKEN" ] || not_run "no auth token (login returned none, or the token query matched no row)"

# Redact the token from the GitHub Actions step log. ZAP echoes the replacer rule
# (token included) to stdout, and `tee` sends stdout to the persisted step log, which
# deleting the console file cannot un-write. ::add-mask:: makes the runner replace this
# exact string wherever it appears in later output — defence in depth, independent of
# what echoes it. nova.ci is public, so the log is world-readable.
echo "::add-mask::${TOKEN}"

# --- fetch the engine's own OpenAPI spec -----------------------------------------------
curl -s -o "$spec_file" "$spec_url" || true
jq -e '.paths | length > 0' "$spec_file" >/dev/null 2>&1 \
    || not_run "the OpenAPI spec was empty — SWAGGER_ENABLE?"
op_count="$(jq '[.paths[] | length] | add // 0' "$spec_file" 2>/dev/null || echo 0)"

# --- scan --------------------------------------------------------------------------
# -S is safe mode: passive observation only. Dropping it turns this into an active scan
# that sends real POST/PUT/DELETE and injection payloads against the seeded API using the
# session this script just created. That is safe here and nowhere else — the database is
# ours, it was created seconds ago and it dies with this job — but it is the most
# dangerous flag in this repository, so it is an explicit mode, never a default.
zap_mode_args=()
case "${DAST_API_SCAN_MODE:-passive}" in
    passive) zap_mode_args+=(-S) ;;
    active)  : ;;
    *) scanner_error "unknown scan-mode: ${DAST_API_SCAN_MODE}" ;;
esac

# -f openapi drives from the spec's real routes, not a spider. The token is
# injected on every request via a replacer rule so ZAP need not model the login itself,
# under the caller's own header and prefix (Authorization/Bearer  for core, unchanged);
# -c/-w and the report/summary shape follow the baseline scan exactly.
#
# The replacement value is wrapped in literal single quotes inside the -z string, and
# that is load-bearing, not tidiness. zap-api-scan.py hands -z to
# `shlex.split()` (zap_common.py:add_zap_options), so a value containing a space is
# split in two: `Bearer eyJ…` became `-config …replacement=Bearer` plus a stray
# positional `eyJ…`, i.e. every request went out with the header set to a bare
# `Bearer` and no token, and the scan silently ran unauthenticated — exactly the
# "it produced the output a working run produces" failure this whole action is built
# against. `db-token` connectors were unaffected only because their prefix is empty.
# A token containing a single quote would break the quoting again; every token we
# inject is base64url or a UUID, neither of which can contain one.
#
# --user: same reasoning as the baseline — /zap/wrk is a bind mount of RUNNER_TEMP on a
# pooled runner, and the zaproxy image's own uid may not have write access to it.
set +e
docker run --rm --network host --user "$(id -u):$(id -g)" \
    -v "$(dirname "$zap_out"):/zap/wrk:rw" "$ZAP_IMAGE" \
    zap-api-scan.py -t "$spec_url" -f openapi \
    ${zap_mode_args[@]+"${zap_mode_args[@]}"} -I \
    -c "$(basename "$zap_conf")" -w "$(basename "$zap_out")" \
    -z "-config replacer.full_list(0).description=auth \
        -config replacer.full_list(0).enabled=true \
        -config replacer.full_list(0).matchtype=REQ_HEADER \
        -config 'replacer.full_list(0).matchstr=${DAST_AUTH_HEADER:-Authorization}' \
        -config 'replacer.full_list(0).replacement=${DAST_AUTH_PREFIX-Bearer }${TOKEN}'" \
    2>&1 | tee "$zap_console"
zap_rc=${PIPESTATUS[0]}
set -e

# Same ladder as zap-baseline.py, verified against the same zap_common.py source: 0
# passes only, 1 is a FAIL-level finding (not a broken scanner — -I does not suppress
# it), 2 is warnings with -I absent (unreachable while -I is passed, kept so removing
# -I never silently turns a findings run into a broken-gate report).
case "$zap_rc" in
    0|1|2) : ;;
    *)     scanner_error "zap-api-scan.py exited ${zap_rc}" ;;
esac

[ -s "$zap_out" ] || scanner_error "ZAP produced no report"

zap_tally_parse "$zap_console" scanner_error

{
    echo "=============================="
    echo " DAST: OWASP ZAP API scan"
    echo " Image:      ${DAST_IMAGE}"
    echo " Spec:       ${spec_url}"
    echo " Operations: ${op_count}"
    echo "=============================="
    echo ""
    echo "must fix (FAIL):   ${failures}"
    echo "warnings (WARN):   ${findings}"
    echo "informational:     ${infos}"
    echo "accepted (IGNORE): ${accepted}"
    echo "passed:            ${passes}"
    echo ""
    cat "$zap_out"
} > "$DAST_REPORT_FILE"

emit failures "$failures"

if [ "$failures" -gt 0 ]; then
    echo "::warning::ZAP API scan reported ${failures} must-fix and ${findings} warning(s). See ${DAST_REPORT_FILE}."
    emit outcome findings
    emit findings "$findings"
    emit_message "🕷 DAST (ZAP API): 🔴 ${failures} must-fix · ${findings} warnings"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    summary WARNING "🔴 ${failures} must-fix and ${findings} warning(s) — the register marks these as blocking."
elif [ "$findings" -gt 0 ]; then
    echo "::warning::ZAP API scan reported ${findings} warning(s). See ${DAST_REPORT_FILE}."
    emit outcome findings
    emit findings "$findings"
    emit_message "🕷 DAST (ZAP API): 🟡 ${findings} warnings"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    summary WARNING "⚠️ ${findings} api-scan warning(s) — review the report."
else
    emit outcome clean
    emit findings 0
    emit_message "🕷 DAST (ZAP API): 🟢 clean · ${op_count} operations · ${infos} info · ${accepted} accepted"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    summary NOTE "✅ No must-fix or warning findings across ${op_count} operations. ${infos} informational, ${accepted} accepted by the triage register."
fi

echo "ZAP API scan — operations: ${op_count}, must-fix: ${failures}, warnings: ${findings}, info: ${infos}, accepted: ${accepted}, passed: ${passes}"
