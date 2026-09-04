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

# shellcheck source=.github/actions/dast/dast-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/dast-common.sh"

: "${DAST_IMAGE:?}" "${DAST_PORT:?}" "${DAST_HEALTH_PATH:?}" "${DAST_BOOT_TIMEOUT:?}"
: "${ZAP_IMAGE:?}" "${DAST_REPORT_FILE:?}" "${DAST_ACTION_ROOT:?}"

DAST_NEEDS_DB="${DAST_NEEDS_DB:-false}"
# Postgres and redis mirror what the platform actually runs, so a scan meets the same
# database the application does — novatalks.charts, novatalks_v5/values.yaml
# (cnpgClusterImage and redis.image). Update both together when the charts move; nothing
# here can detect that drift, since a check inside this repo would only compare a
# constant with itself.
DAST_NEEDS_NATS="${DAST_NEEDS_NATS:-false}"
DAST_EXTRA_ENV="${DAST_EXTRA_ENV:-}"
# Applied only when .env.example could NOT be seeded — see the scanned_repo/workspace_repo
# check below, which is the one place this gets merged into DAST_EXTRA_ENV. Never applied
# when the file was seeded: on the build workflow's own path the scanned application's
# real .env.example already carries these values (its own S3 config among them, for
# novatalks.core), and this fallback must not override a value that is already correct
# there — see targets.sh's novatalks.core/browser arm and CLAUDE.md's R2/S3 exception for
# why. DAST_EXTRA_ENV stays the one mechanism the app container ever sees; this variable
# only decides whether a second string gets folded into it before that mechanism runs.
DAST_UNSEEDED_ENV="${DAST_UNSEEDED_ENV:-}"
# The repository whose image is being scanned — not necessarily the repository this job
# runs in. Every caller until now was the reusable build workflow, which runs in the
# product repository's own context, so GITHUB_REPOSITORY named the scanned repository by
# accident of who called. ci-dast-pentest.yaml runs in nova.ci and scans somebody else's
# image, and two things below key off this name: the postgres major version, and whether
# the checkout sitting in GITHUB_WORKSPACE is the scanned repository's own. The input
# wins when set; the fallback reproduces every pre-existing caller byte for byte.
DAST_TARGET_REPO="${DAST_TARGET_REPO:-}"
# GITHUB_REPOSITORY is always set on a real Actions run; the :- default here only
# keeps `set -u` from aborting when a developer runs this script (or the harness)
# locally without it — the stripped value is identical either way.
github_repository="${GITHUB_REPOSITORY:-}"
workspace_repo="${github_repository##*/}"
scanned_repo="${DAST_TARGET_REPO:-$workspace_repo}"
if [ -n "$DAST_TARGET_REPO" ]; then
    repo_source="the target-repository input"
else
    repo_source="GITHUB_REPOSITORY"
fi
# Two distinct URLs: the boot probe polls the health path, ZAP scans the root. They are
# not interchangeable — on novatalks.ui the health path 404s — so the summary and the
# report header name the URL that was actually scanned, not the one that was polled.
target="http://127.0.0.1:${DAST_PORT}"
health_url="${target}${DAST_HEALTH_PATH}"
# ZAP's own artifacts (the -w report, the copied triage register, and — in full mode —
# the copied context file) live in a directory of their own, never the whole of
# RUNNER_TEMP: that directory also holds app_tmp_env (a stripped-but-real
# .env.example) and other job temp files, and the container needs this one
# world-writable (see the "no --user" comment near the docker run below) — chmod'ing
# the whole of RUNNER_TEMP would leave those other files' directory entries
# world-writable too, and outlive this job's own cleanup trap on a pooled, reused
# runner. Made and torn down here rather than by mkdir -p at first use, because the
# permission bit has to be set before ZAP ever writes into it.
zap_work_dir="${RUNNER_TEMP:-/tmp}/zap-wrk"
mkdir -p "$zap_work_dir"
chmod 777 "$zap_work_dir"
zap_out="${zap_work_dir}/zap.md"
# zap-baseline.py's -w report is the human-readable markdown one; the WARN-NEW lines
# the finding count comes from are printed to stdout only, never into that file.
zap_console="${RUNNER_TEMP:-/tmp}/zap-console.log"
# The triage register: which findings must be fixed, which are accepted, and why. Copied
# into zap_work_dir because zap-baseline.py (and zap-full-scan.py, same resolution logic)
# resolves -c against /zap/wrk/ and nowhere else, and /zap/wrk is the bind mount of that
# directory. zap_conf_src/zap_conf/zap_script/zap_mode_args are set below, once
# scanner_error exists — the mode is invalid input, same as a missing register, and
# reported the same way.
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
    emit failures 0
    emit_message "🕷 DAST (ZAP): ⚠️ not run — $1"
    summary WARNING "Scan did not run: $1. This is not a clean result."
    { echo "=== DAST: not run ==="; echo "$1"; } > "$DAST_REPORT_FILE"
    exit 0
}

scanner_error() { # scanner_error <reason>
    echo "::error::DAST scanner failed: $1"
    emit outcome error
    emit findings 0
    emit failures 0
    emit_message "🕷 DAST (ZAP): ❌ scanner failed — $1"
    summary CAUTION "The scanner itself failed: $1. This is a broken gate."
    exit 2
}

# baseline observes; full attacks. Two scripts, two spiders, two registers — and the
# exit ladder and tally line are identical between them, verified against
# zap-full-scan.py:480 and :511-522, which is why dast-common.sh is untouched.
case "${DAST_SCAN_MODE:-baseline}" in
    baseline)
        zap_script=zap-baseline.py
        zap_conf_name=zap-baseline.conf
        zap_mode_args=()
        ;;
    full)
        zap_script=zap-full-scan.py
        zap_conf_name=zap-full-scan.conf
        # -j swaps the traditional spider for the modern one. Without it a single-page
        # app is exactly one page to ZAP: nginx serves index.html for every route and the
        # traditional spider has no JavaScript to follow.
        zap_mode_args=(-j)
        # A context file teaches ZAP the login form. Without one the "authenticated"
        # scan is an anonymous crawl that looks exactly like a successful one — the same
        # failure shape as the unquoted -z replacer in dast-api. -U names the user
        # defined inside the context; both flags travel together or neither does.
        if [ -n "${DAST_ZAP_CONTEXT:-}" ]; then
            # Validated, not just copied. A typo in the filename used to make `cp` fail
            # under set -e: exit 1 with a bare "cp: cannot stat", no outcome, no message,
            # no summary and an empty notifier line — the one input-validation path in
            # this file that did not report itself. Same treatment as the triage register.
            zap_context_src="${DAST_ACTION_ROOT}/contexts/${DAST_ZAP_CONTEXT}"
            [ -r "$zap_context_src" ] || scanner_error "the ZAP context file is missing or unreadable: ${zap_context_src}"
            cp "$zap_context_src" "${zap_work_dir}/"
            zap_mode_args+=(-n "$DAST_ZAP_CONTEXT" -U nova-ci-dast)
        fi
        ;;
    *) scanner_error "unknown scan-mode: ${DAST_SCAN_MODE}" ;;
esac
zap_conf_src="${DAST_ACTION_ROOT}/${zap_conf_name}"
zap_conf="${zap_work_dir}/${zap_conf_name}"

# Validated before anything is booted: a broken register means ZAP silently applies a
# policy nobody wrote, and finding that out after a five-minute stack boot helps nobody.
# ZAP's own handling is loud enough (sys.exit(3) on a malformed line, an uncaught
# FileNotFoundError on a missing one) but its reason lands in a log nobody reads, and a
# check of our own is one the harness can cover.
[ -r "$zap_conf_src" ] || scanner_error "the ZAP triage register is missing or unreadable: ${zap_conf_src}"

# Grammar per zap_common.py:148-176 — at least two tabs, and a level from the fixed set
# at zap_common.py:57 plus OUTOFSCOPE, which load_config checks before the level list.
# What this cannot catch is a well-formed line naming a rule ID that does not exist: ZAP
# reports alert counts per bucket, never which configured IDs matched, so an IGNORE that
# applied and an IGNORE that was mistyped are indistinguishable from the outside.
conf_bad="$(awk -F'\t' '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    NF < 3 { printf "line %d: fewer than three tab-separated fields; ", NR; next }
    $2 != "PASS" && $2 != "IGNORE" && $2 != "INFO" && $2 != "WARN" && $2 != "FAIL" && $2 != "OUTOFSCOPE" {
        printf "line %d: unknown level \"%s\"; ", NR, $2 }
' "$zap_conf_src")"
[ -z "$conf_bad" ] || scanner_error "the ZAP triage register is malformed — ${conf_bad}"
cp "$zap_conf_src" "$zap_conf"

if [ "$DAST_NEEDS_DB" = "true" ]; then
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
    # The choice used to be silent, which is how a pentest dispatch for novatalks.core
    # could get postgres:16: the name it keys off came from the runner's repository, not
    # the scanned one, and nothing said so. Name the image, the repository it was chosen
    # for, and where that name came from.
    echo "DAST postgres: ${PG_IMAGE} — chosen for '${scanned_repo}' (from ${repo_source})."
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
    # dast-common.sh's dast_bring_up_nats: shared with dast-api/scan.sh so the bring-up
    # sequence (image, ports, JetStream flag, the 'campaign' stream, the js-init.sh
    # cross-reference) exists in exactly one place rather than as two copies that can
    # drift apart.
    dast_bring_up_nats not_run "$nats_stream_log"
fi

# .env.example is resolved relative to the workspace, not to this action's own
# checkout, since it belongs to the product repo whose image is being scanned.
env_file_path="${GITHUB_WORKSPACE:-.}/.env.example"

# ...which only holds if the workspace really is that repository's checkout. Under
# ci-dast-pentest.yaml it is not: that workflow runs in nova.ci, and nova.ci has an
# .env.example of its own. Seeding it would hand the scanned container four unrelated
# variables, log a perfectly plausible "seeded 4 variable(s)", and then blame the image
# for the boot it caused — the same shape as the @local admin address.
#
# A warning rather than a loud skip, deliberately: the repositories whose browser scan
# needs no seeding at all (novatalks.ui is a static nginx image) would be killed outright
# by a not_run here, and a scan that CAN run must not be stopped by a file it never
# wanted. What the loud skip is for instead is the case where the application then fails
# to boot: env_skip_note travels into that message so the failure names our own missing
# input rather than the image.
env_skip_note=""
if [ "$scanned_repo" != "$workspace_repo" ]; then
    echo "::warning::DAST env file: not seeded. GITHUB_WORKSPACE holds a checkout of '${workspace_repo:-unknown}', not of the scanned repository '${scanned_repo}', so its .env.example is another repository's configuration, not this application's."
    env_skip_note=" — and no .env.example was seeded, because GITHUB_WORKSPACE holds a checkout of '${workspace_repo:-unknown}', not of '${scanned_repo}'"
    # The one branch DAST_UNSEEDED_ENV is allowed to reach: nothing real was seeded, so
    # there is no correct value here for a fallback to clobber. Folded into
    # DAST_EXTRA_ENV ahead of the single parsing loop below rather than a second copy of
    # it — same -e-after-env-file semantics, same log line, one parser for both strings.
    if [ -n "$DAST_UNSEEDED_ENV" ]; then
        echo "DAST unseeded-env: applying ${scanned_repo}'s boot fallback (no .env.example was available to seed it)."
        DAST_EXTRA_ENV="${DAST_UNSEEDED_ENV}
${DAST_EXTRA_ENV}"
    fi
elif [ -f "$env_file_path" ]; then
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
    echo "DAST env file (.env.example): seeded ${seeded_count} variable(s); dropped ${comment_dropped} line(s) with a trailing comment, ${node_env_dropped} NODE_ENV line(s), ${empty_dropped} line(s) with an empty value."

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
echo "DAST port: forcing PORT and APP_PORT to ${DAST_PORT}, overriding anything seeded from .env.example."

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
    not_run "the image did not come up within ${DAST_BOOT_TIMEOUT}s${env_skip_note}"
fi

# No --user: the container runs as the image's own default user, `zap` (uid 1000), with
# its real HOME=/home/zap and the add-ons it ships with. zap-baseline.py's Automation
# Framework writes its plan there (Path.home(), zap-baseline.py:465-467), so overriding
# HOME instead of the uid would move ~/.ZAP and orphan those add-ons — rejected for that
# reason. Confirmed live (run 33867417238) that ci-dast-pentest.yaml's ubuntu-latest
# runner (uid 1001) hit exactly the failure this predicts when --user forced ZAP to run
# as 1001 with no write access to /home/zap: "Failed to start ZAP", exit 3, 0.26s after
# the image pulled — before any scan happened.
#
# zap_work_dir is chmod 777 above so the `zap` user can write into it regardless of
# which uid the host process runs as: 1000 on the self-hosted pool (the same uid the
# image defaults to, so this is a no-op change in effect there), 1001 on ubuntu-latest.
# All four ZAP callers in this repository (this file, dast-api/scan.sh,
# ci-dast-live-baseline.yaml, and the live-target step in ci-dast-pentest.yaml) now share
# this one approach rather than the self-hosted-only `--user "$(id -u):$(id -g)"` this
# file used to carry.
set +e
docker run --rm --network host \
    -v "$(dirname "$zap_out"):/zap/wrk:rw" \
    "$ZAP_IMAGE" "$zap_script" -t "$target" \
    ${zap_mode_args[@]+"${zap_mode_args[@]}"} \
    -I -c "$(basename "$zap_conf")" -w "$(basename "$zap_out")" 2>&1 | tee "$zap_console"
# PIPESTATUS[0], not $?: it is ZAP's own exit status, unambiguously. $? happens to
# agree only because pipefail is set above; it would silently become tee's status the
# moment that changed, and it is tee's status whenever tee itself fails.
zap_rc=${PIPESTATUS[0]}
set -e

# The ladder, verified against zap-baseline.py:697-708 rather than assumed:
#   0  passes only
#   1  FAIL-level findings present — a finding, not a broken scanner. -I does NOT
#      suppress this; it gates exit 2 alone (`elif (not ignore_warn) and warn_count`).
#      An earlier comment here claimed -I made 1 unreachable, which was simply wrong,
#      and would have reddened a trunk build for a finding the first time the triage
#      register gained a FAIL entry.
#   2  warnings with -I absent — unreachable while we pass -I, kept so that removing -I
#      never silently turns a findings run into a broken-gate report.
#   3  an exception, or nothing passed, warned or failed at all. Both are broken gates.
case "$zap_rc" in
    0|1|2) : ;;
    *)     scanner_error "zap-baseline.py exited ${zap_rc}" ;;
esac

[ -s "$zap_out" ] || scanner_error "ZAP produced no report"

# Counted from stdout, not from the -w report: that report is the traditional
# "ZAP Scanning Report" markdown (## Summary of Alerts + per-risk sections) and contains
# no WARN-NEW at all, so counting it there is a permanent zero — every run green,
# including one with twenty warnings.
#
# One tally line carries all six numbers and is printed unconditionally at the end of any
# completed scan (zap-baseline.py:666-668), which is why it is read instead of the
# per-rule `^WARN-NEW: ` lines: those give one of the six. Its absence means the scan did
# not complete, and an unfinished scan reporting zero findings is precisely the failure
# this job exists to avoid — fail closed, the same shape as the Semgrep canary.
#
# A bare `^FAIL-NEW: ` prefix is not enough to find it: print_rule (zap_common.py:205)
# emits one per-rule line per FAIL-level finding shaped `FAIL-NEW: <alert name> [<id>]
# x <n>`, which starts with the exact same prefix and comes before the tally whenever a
# FAIL entry exists. `grep -m1` would take that line instead, tally_at would read an
# alert name where a number belongs, and the numeric guard below would misreport a real
# FAIL finding as a broken scanner — the collapse this task exists to prevent. The tally
# line's shape is unique: `FAIL-NEW: <digits>` immediately followed by a tab and
# `FAIL-INPROG: ` (per-rule in-progress lines are spelled `-IN_PROGRESS:`, never
# `-INPROG:`, per zap_common.py:201), so anchoring on that shape instead of the prefix
# alone cannot match a per-rule line.
#
# $'...' is load-bearing, not decoration: it is ANSI-C quoting, so the pattern reaches
# grep carrying a real tab byte. Written as a plain '...' string the pattern carries a
# backslash and a `t`, which BSD grep interprets as a tab but GNU grep does not — GNU
# warns `stray \ before t` and matches a literal `t`, so the tally never matches, every
# completed scan reports "no tally" and reds the build. Every runner is GNU; a macOS
# harness run is the one place the broken form passes. Do not "tidy" it back.
zap_tally_parse "$zap_console" scanner_error

{
    echo "=============================="
    echo " DAST: OWASP ZAP baseline"
    echo " Image:  ${DAST_IMAGE}"
    echo " Target: ${target}"
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
    echo "::warning::ZAP baseline reported ${failures} must-fix and ${findings} warning(s). See ${DAST_REPORT_FILE}."
    emit outcome findings
    emit findings "$findings"
    emit_message "🕷 DAST (ZAP): 🔴 ${failures} must-fix · ${findings} warnings"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    summary WARNING "🔴 ${failures} must-fix and ${findings} warning(s) — the register marks these as blocking."
elif [ "$findings" -gt 0 ]; then
    echo "::warning::ZAP baseline reported ${findings} warning(s). See ${DAST_REPORT_FILE}."
    emit outcome findings
    emit findings "$findings"
    emit_message "🕷 DAST (ZAP): 🟡 ${findings} warnings"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    summary WARNING "⚠️ ${findings} baseline warning(s) — review the report."
else
    emit outcome clean
    emit findings 0
    emit_message "🕷 DAST (ZAP): 🟢 clean · ${infos} info · ${accepted} accepted"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    summary NOTE "✅ No must-fix or warning findings. ${infos} informational, ${accepted} accepted by the triage register."
fi

echo "ZAP baseline — must-fix: ${failures}, warnings: ${findings}, info: ${infos}, accepted: ${accepted}, passed: ${passes}"
