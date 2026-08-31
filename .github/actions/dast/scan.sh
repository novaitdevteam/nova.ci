#!/usr/bin/env bash
#
# Bring up the built image with its dependencies, run an OWASP ZAP baseline against it,
# tear everything down, and report one of four outcomes.
#
# The four are deliberately distinct. `clean` and `not-run` in particular must never
# collapse: an application that failed to boot produces exactly the same empty ZAP
# report as a perfectly clean one, and reporting that as clean is the failure this
# whole job exists to avoid. A failed boot is a loud skip with the build left green —
# it comes from .env drift or a missing migration, not from a vulnerability. ZAP itself
# failing is different again, and reds the job.
#
# Some engines (novatalks.core, S3 config among other things) will not boot on
# DATABASE_*/REDIS_* alone. Rather than hardcode product-specific env vars here — or
# worse, a credential — this reads the product repo's own .env.example, the same file
# ci-build-ntk-on-push-tags-run-test.yaml already trusts for integration tests, and
# hands it to the app container via --env-file. That file may carry credentials, so the
# stripped copy lives only under RUNNER_TEMP, is never echoed, and never reaches the
# report or the job summary.
#
set -euo pipefail

: "${DAST_IMAGE:?}" "${DAST_PORT:?}" "${DAST_HEALTH_PATH:?}" "${DAST_BOOT_TIMEOUT:?}"
: "${ZAP_IMAGE:?}" "${DAST_REPORT_FILE:?}"

DAST_NEEDS_DB="${DAST_NEEDS_DB:-false}"
# Postgres and redis mirror what the platform actually runs, so a scan meets the same
# database the application does — novatalks.charts, novatalks_v5/values.yaml
# (cnpgClusterImage and redis.image). Update both together when the charts move; nothing
# here can detect that drift, since a check inside this repo would only compare a
# constant with itself.
DAST_PG_IMAGE="${DAST_PG_IMAGE:-ghcr.io/cloudnative-pg/postgresql:18.4-standard-trixie}"
DAST_NEEDS_NATS="${DAST_NEEDS_NATS:-false}"
DAST_NATS_STREAM="${DAST_NATS_STREAM:-campaign}"
DAST_NATS_SUBJECTS="${DAST_NATS_SUBJECTS:-campaign.*}"
DAST_NATS_BOX_IMAGE="${DAST_NATS_BOX_IMAGE:-natsio/nats-box:0.19.7}"
DAST_ENV_FILE="${DAST_ENV_FILE:-.env.example}"
DAST_EXTRA_ENV="${DAST_EXTRA_ENV:-}"
# Two distinct URLs: the boot probe polls the health path, ZAP scans the root. They are
# not interchangeable — on novatalks.ui the health path 404s — so the summary and the
# report header name the URL that was actually scanned, not the one that was polled.
target="http://127.0.0.1:${DAST_PORT}"
health_url="${target}${DAST_HEALTH_PATH}"
zap_out="${RUNNER_TEMP:-/tmp}/zap.md"
# zap-baseline.py's -w report is the human-readable markdown one; the WARN-NEW lines
# the finding count comes from are printed to stdout only, never into that file.
zap_console="${RUNNER_TEMP:-/tmp}/zap-console.log"
# Printed on failure, never suppressed: a stream that cannot be created must say why.
nats_stream_log="${RUNNER_TEMP:-/tmp}/nats-stream.log"
app_env_args=()
app_tmp_env=""
app_db_args=()
extra_env_args=()

emit() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }

emit_message() {
    {
        echo "message<<DAST_EOF"
        printf '%s\n' "$1"
        echo "DAST_EOF"
    } >> "${GITHUB_OUTPUT:-/dev/null}"
}

cleanup() {
    docker rm -f nova-app nova-pg nova-redis nova-nats >/dev/null 2>&1 || true
    # Self-hosted runners are pooled and reused, not thrown away after one job, so a
    # temp file that may carry S3/database credentials must not outlive this process —
    # RUNNER_TEMP is not guaranteed wiped before the next job lands on the same VM.
    [ -n "$app_tmp_env" ] && rm -f "$app_tmp_env" >/dev/null 2>&1 || true
    # The console log is a counting artefact, never an artifact: it holds raw ZAP
    # output about a container that was booted with the product repo's own env.
    rm -f "$zap_console" "$nats_stream_log" >/dev/null 2>&1 || true
}
trap cleanup EXIT

summary() { # summary <alert> <headline>
    {
        echo "## 🕷 DAST (ZAP baseline)"
        echo ""
        echo "> [!$1]"
        echo "> $2"
        echo ""
        echo "- Image: \`${DAST_IMAGE}\`"
        echo "- Target: \`${target}\`"
        echo "- Report: ${REPORT_URL:-not published}"
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

not_run() { # not_run <reason>
    echo "::warning::DAST did not run: $1"
    emit outcome not-run
    emit findings 0
    emit_message "🕷 DAST (ZAP): ⚠️ not run — $1"
    summary WARNING "Scan did not run: $1. This is not a clean result."
    { echo "=== DAST: not run ==="; echo "$1"; } > "$DAST_REPORT_FILE"
    exit 0
}

scanner_error() { # scanner_error <reason>
    echo "::error::DAST scanner failed: $1"
    emit outcome error
    emit findings 0
    emit_message "🕷 DAST (ZAP): ❌ scanner failed — $1"
    summary CAUTION "The scanner itself failed: $1. This is a broken gate."
    exit 2
}

if [ "$DAST_NEEDS_DB" = "true" ]; then
    docker rm -f nova-pg nova-redis >/dev/null 2>&1 || true
    docker run -d --name nova-pg -p 5432:5432 \
        -e POSTGRES_PASSWORD="${DATABASE_PASSWORD:-password}" \
        -e POSTGRES_USER="${DATABASE_USERNAME:-postgres}" \
        -e POSTGRES_DB="${DATABASE_NAME:-db_name}" \
        "$DAST_PG_IMAGE" || not_run "postgres did not start"
    docker run -d --name nova-redis -p 6379:6379 redis:8.6.4 || not_run "redis did not start"
    for _ in $(seq 1 30); do
        docker exec nova-pg pg_isready -U "${DATABASE_USERNAME:-postgres}" >/dev/null 2>&1 && break
        sleep 2
    done
    docker exec -e PGPASSWORD="${DATABASE_PASSWORD:-password}" nova-pg \
        psql -h 127.0.0.1 -U "${DATABASE_USERNAME:-postgres}" -d "${DATABASE_NAME:-db_name}" \
        -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;" >/dev/null 2>&1 || true

    # Two conventions coexist deliberately: DATABASE_HOST/PORT/USERNAME/PASSWORD/NAME
    # below serve the Sequelize repositories, this single DATABASE_URL serves the Prisma
    # ones (nova.chatsconnector.telegram-client-api among them) which have no discrete
    # host/user/pass vars to bind to. Both are built from the very same values just
    # handed to the postgres container above, so they cannot name a different database
    # than the one this script actually started. Never set when no database is started —
    # a URL pointing at a postgres that was never brought up is worse than none.
    app_db_args=(-e "DATABASE_URL=postgresql://${DATABASE_USERNAME:-postgres}:${DATABASE_PASSWORD:-password}@127.0.0.1:5432/${DATABASE_NAME:-db_name}")
fi

if [ "$DAST_NEEDS_NATS" = "true" ]; then
    docker rm -f nova-nats >/dev/null 2>&1 || true
    # No config file, no auth, no TLS, no JetStream: the client side (novatalks.dialer's
    # own .env.example) defaults to exactly this — NATS_USER/NATS_PASS/NATS_NKEY/NATS_JWT
    # all blank, NATS_TLS_ENABLED=false, NATS_STREAM_ENABLED=false. Production NATS
    # (nats-system/ntk-nats-prod-cluster) is a three-node cluster with TLS and
    # NKEY/account auth; none of that is needed here, and mirroring it would scan
    # something the client was never configured to reach. `-m 8222` turns on the
    # monitoring endpoint the wait-loop below polls; it costs nothing else.
    #
    # Tag-pinned, not digest-pinned, matching the postgres and redis images in this
    # script: infrastructure containers here follow that precedent, digest pinning is
    # reserved for the scanners themselves (Semgrep, ZAP).
    docker run -d --name nova-nats -p 4222:4222 -p 8222:8222 \
        nats:2.10-alpine -js -m 8222 || not_run "NATS did not start"
    nats_ready=no
    for _ in $(seq 1 30); do
        code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8222/healthz || true)"
        if [ -n "$code" ] && [ "$code" != "000" ]; then nats_ready=yes; break; fi
        sleep 2
    done
    [ "$nats_ready" = "yes" ] || not_run "NATS did not become ready"

    # A running JetStream is not enough: the dialer asks $JS.API.STREAM.NAMES for a
    # subject and throws "no stream matches subject" when nothing owns it. Mirrors
    # ~/novatalks/scripts/nats-docker/scripts/js-init.sh, the stand the team already
    # uses locally — same stream, same subjects, same retention — minus its `nsc push`
    # step, which provisions JWT accounts this unauthenticated server has no use for.
    # Keep the two comparable: if that script's stream changes, this should follow.
    docker run --rm --network host "$DAST_NATS_BOX_IMAGE" \
        nats --server 127.0.0.1:4222 stream add "$DAST_NATS_STREAM" \
            --subjects "$DAST_NATS_SUBJECTS" \
            --storage file --replicas 1 \
            --retention work --discard old \
            --max-msgs=-1 --max-msgs-per-subject=-1 --max-bytes=-1 \
            --max-age=-1 --max-msg-size=-1 \
            --dupe-window=2m --no-allow-rollup --no-deny-delete --no-deny-purge \
            --defaults > "$nats_stream_log" 2>&1 \
        || { sed 's/^/    /' "$nats_stream_log" 2>/dev/null || true
             not_run "could not create the '${DAST_NATS_STREAM}' JetStream stream"; }
fi

# .env.example is resolved relative to the workspace, not to this action's own
# checkout, since it belongs to the product repo whose image is being scanned.
case "$DAST_ENV_FILE" in
    /*) env_file_path="$DAST_ENV_FILE" ;;
    *)  env_file_path="${GITHUB_WORKSPACE:-.}/${DAST_ENV_FILE}" ;;
esac

if [ -f "$env_file_path" ]; then
    app_tmp_env="${RUNNER_TEMP:-/tmp}/dast.env"
    stage="${app_tmp_env}.stage"

    # Two filters, mirroring ci-build-ntk-on-push-tags-run-test.yaml's own
    # `sed '/^#/d'` + `grep -E '^[A-Za-z_][A-Za-z0-9_]*='`: comments are dropped, and so
    # is any bare-key line with no `=`. Docker's --env-file treats a bare key as "pass
    # through this process's own value of that variable" — a bare key in the product
    # repo's .env.example that happens to match a name in scan.sh's own environment
    # would otherwise leak it into the scanned container. --env-file still parses the
    # surviving KEY=value lines natively, including values containing `=` or spaces, so
    # they are handed through rather than re-parsed into -e flags.
    grep -v '^[[:space:]]*#' "$env_file_path" \
        | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' > "$stage" || true
    candidate_count=$(grep -c . "$stage" || true)
    candidate_count="${candidate_count:-0}"

    # .env.example is a human-facing file, and a value written `production // comment`
    # is documentation, not a value with a suffix. Docker's --env-file strips whole-line
    # comments only, never a trailing one, so the comment text became part of the value
    # — this is exactly what broke novatalks.core's boot (NODE_ENV picked up the literal
    # string "production // production, development, test", and Sequelize CLI found no
    # config section by that name). Anchor the drop on the whitespace before `//` or `#`
    # so a URL value (`https://…`, no space before its own `//`) survives. A line with a
    # trailing comment is dropped outright, never trimmed — guessing where the value
    # ends is how a password containing ` #` gets corrupted instead of dropped.
    grep -vE '[[:space:]](//|#)' "$stage" > "$app_tmp_env" || true
    kept_count=$(grep -c . "$app_tmp_env" || true)
    kept_count="${kept_count:-0}"
    comment_dropped=$(( candidate_count - kept_count ))

    # NODE_ENV selects the application's own code paths and config sections, and the
    # image already sets it correctly (`ENV NODE_ENV=production`). Seeding it from the
    # product repo's own documentation file can only override a correct value with a
    # wrong one, comment or not — so it is filtered out by name, independent of whether
    # this particular line also tripped the comment filter above.
    grep -vE '^NODE_ENV=' "$app_tmp_env" > "$stage" || true
    mv "$stage" "$app_tmp_env"
    node_env_kept_count=$(grep -c . "$app_tmp_env" || true)
    node_env_kept_count="${node_env_kept_count:-0}"
    node_env_dropped=$(( kept_count - node_env_kept_count ))

    # Docker's --env-file does not strip quotes the way dotenv (what .env.example files
    # are written for) does: a value written DATABASE_URL="postgresql://..." reaches the
    # container as a string that literally starts with '"', and Prisma/pg refuse it.
    # Strip only a matching pair of surrounding quotes — first and last character both
    # `"` or both `'` — and nothing else: an inner quote stays, an unmatched leading quote
    # with no trailing one stays, and no whitespace is trimmed. That is dotenv's own rule.
    #
    # Fourth instance of the same shape as the comment, NODE_ENV and port filters above:
    # a value left blank in a template ("KEY=") means "fill this in", not "set this to
    # the empty string", and passing that empty string through is strictly worse than
    # dropping the line — novatalks.dialer declares
    # `MEMORY_RSS_THRESHOLD: Joi.number().integer().default(0)`, a perfectly good
    # default, but Joi only applies a default when a value is undefined, and an empty
    # string is a value; it dies with "MEMORY_RSS_THRESHOLD" must be a number instead of
    # booting on its own default. Dropping the line lets that default apply, and a
    # variable that is genuinely required will fail loudly by its own name — a far
    # better diagnostic than a type error two layers down. A whitespace-only value is
    # dropped for the same reason: "   " is not a real value either, just a value nobody
    # bothered to trim out of the template.
    empty_dropped=0
    while IFS= read -r env_line || [ -n "$env_line" ]; do
        env_key="${env_line%%=*}"
        env_val="${env_line#*=}"
        val_len=${#env_val}
        if [ "$val_len" -ge 2 ]; then
            first_ch="${env_val:0:1}"
            last_ch="${env_val: -1}"
            if { [ "$first_ch" = '"' ] && [ "$last_ch" = '"' ]; } \
                || { [ "$first_ch" = "'" ] && [ "$last_ch" = "'" ]; }; then
                env_val="${env_val:1:val_len-2}"
            fi
        fi
        trimmed_val="${env_val%%[![:space:]]*}"
        trimmed_val="${env_val#"$trimmed_val"}"
        if [ -z "$trimmed_val" ]; then
            empty_dropped=$((empty_dropped + 1))
            continue
        fi
        printf '%s=%s\n' "$env_key" "$env_val"
    done < "$app_tmp_env" > "$stage"
    mv "$stage" "$app_tmp_env"
    seeded_count=$(grep -c . "$app_tmp_env" || true)
    seeded_count="${seeded_count:-0}"

    # Names and counts only, never values: this file may carry credentials. The absence
    # of exactly this line is why diagnosing the novatalks.core boot failure took as
    # many steps as it did.
    echo "DAST env file (${DAST_ENV_FILE}): seeded ${seeded_count} variable(s); dropped ${comment_dropped} line(s) with a trailing comment, ${node_env_dropped} NODE_ENV line(s), ${empty_dropped} line(s) with an empty value."

    app_env_args=(--env-file "$app_tmp_env")
fi

# Per-repository escape hatch, not a filter fix: some values in .env.example are
# deliberately unusable template placeholders (an angle-bracket account ID, a redacted
# example) that a config validator rejects outright, and no amount of comment/quote
# stripping above turns a placeholder into a real value. One -e per non-blank line,
# after --env-file so it wins over whatever the seeded file said; the value after the
# first `=` is passed through verbatim, so a value containing `=` survives. Only the
# count is logged, never the content — a future caller may put something sensitive
# here even though today's only use is a dummy URL.
extra_applied=0
if [ -n "$DAST_EXTRA_ENV" ]; then
    while IFS= read -r extra_line || [ -n "$extra_line" ]; do
        trimmed="${extra_line#"${extra_line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        [ -z "$trimmed" ] && continue
        extra_env_args+=(-e "$trimmed")
        extra_applied=$((extra_applied + 1))
    done <<< "$DAST_EXTRA_ENV"
fi
[ "$extra_applied" -gt 0 ] && echo "DAST extra-env: applied ${extra_applied} override(s)."

# The action owns three things a seeded .env.example must never be trusted to decide,
# because that file is written for a human, not for this scan: NODE_ENV (filtered out
# above), quoting (stripped above), and — the third instance of the same shape of bug —
# the listen port, forced here. nova.chatsconnector.signal-client-api's .env.example
# read APP_PORT=5555 while its chart containerPort, its Dockerfile EXPOSE and the
# Resolve DAST target step all agreed on 3000; the app booted on 5555, the wait-loop
# below polled 3000, and a perfectly healthy boot reported "not run". PORT and APP_PORT
# both, because the repositories disagree on the name — nova.chatsconnector.whatsapp-client-api
# reads PORT, novatalks.core and the telegram and signal connectors read APP_PORT — and
# both after --env-file, so whatever the template said loses. An app that reads neither
# (novatalks.ui, served through nginx) is unaffected. This is also what keeps the wait
# loop, ZAP and the app container itself agreed on one port instead of three.
echo "DAST port: forcing PORT and APP_PORT to ${DAST_PORT}, overriding anything seeded from ${DAST_ENV_FILE}."

# Same "the action owns this, not the template" reasoning as PORT/APP_PORT above, for a
# different failure shape: novatalks.dialer's own boot log read
# "Error: connect ECONNREFUSED ::1:4222" — the client resolved `localhost` to IPv6, and a
# NATS server bound to 0.0.0.0 still refuses that connection. Naming 127.0.0.1 explicitly
# removes the resolution question rather than hoping the app or its host resolver picks
# the v4 address. After --env-file so it wins over whatever the seeded template said.
docker rm -f nova-app >/dev/null 2>&1 || true
docker run -d --name nova-app --network host \
    ${app_env_args[@]+"${app_env_args[@]}"} \
    ${extra_env_args[@]+"${extra_env_args[@]}"} \
    -e DATABASE_HOST=127.0.0.1 -e DATABASE_PORT=5432 \
    -e DATABASE_USERNAME="${DATABASE_USERNAME:-postgres}" \
    -e DATABASE_PASSWORD="${DATABASE_PASSWORD:-password}" \
    -e DATABASE_NAME="${DATABASE_NAME:-db_name}" \
    ${app_db_args[@]+"${app_db_args[@]}"} \
    -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6379 \
    -e PORT="$DAST_PORT" -e APP_PORT="$DAST_PORT" \
    -e NATS_SERVERS=127.0.0.1:4222 \
    "$DAST_IMAGE" || not_run "the application container refused to start"

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

# --user: the zaproxy image runs as uid 1000, and /zap/wrk is a bind mount of
# RUNNER_TEMP on a pooled self-hosted runner. If that directory is owned by another uid
# without group write, write_report raises IOError and ZAP exits 3 — a red build from a
# permission bit. Running as the runner's own uid sidesteps it.
set +e
docker run --rm --network host --user "$(id -u):$(id -g)" \
    -v "$(dirname "$zap_out"):/zap/wrk:rw" \
    "$ZAP_IMAGE" zap-baseline.py -t "$target" \
    -I -w "$(basename "$zap_out")" 2>&1 | tee "$zap_console"
# PIPESTATUS[0], not $?: it is ZAP's own exit status, unambiguously. $? happens to
# agree only because pipefail is set above; it would silently become tee's status the
# moment that changed, and it is tee's status whenever tee itself fails.
zap_rc=${PIPESTATUS[0]}
set -e

# zap-baseline.py: 0 = nothing, 2 = warnings present (with -I it never returns 1),
# anything else means ZAP could not do its job.
case "$zap_rc" in
    0|2) : ;;
    *)   scanner_error "zap-baseline.py exited ${zap_rc}" ;;
esac

[ -s "$zap_out" ] || scanner_error "ZAP produced no report"

# Counted from stdout, not from the -w report: that report is the traditional
# "ZAP Scanning Report" markdown (## Summary of Alerts + per-risk sections) and contains
# no WARN-NEW at all, so counting it there is a permanent zero — every run green,
# including one with twenty warnings. `^WARN-NEW: ` matches the per-rule lines only; the
# trailing tally line starts with FAIL-NEW:.
findings=$(grep -cE '^WARN-NEW: ' "$zap_console" || true)
findings="${findings:-0}"

{
    echo "=============================="
    echo " DAST: OWASP ZAP baseline"
    echo " Image:  ${DAST_IMAGE}"
    echo " Target: ${target}"
    echo "=============================="
    echo ""
    cat "$zap_out"
} > "$DAST_REPORT_FILE"

if [ "$findings" -gt 0 ]; then
    echo "::warning::ZAP baseline reported ${findings} warning(s). See ${DAST_REPORT_FILE}."
    emit outcome findings
    emit findings "$findings"
    emit_message "🕷 DAST (ZAP): 🟡 ${findings} warnings"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    summary WARNING "⚠️ ${findings} baseline warning(s) — review the report."
else
    emit outcome clean
    emit findings 0
    emit_message "🕷 DAST (ZAP): 🟢 clean"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    summary NOTE "✅ No baseline warnings."
fi

echo "ZAP baseline — warnings: ${findings}"
