#!/usr/bin/env bash
# Bring the whole NovaTalks stack up on a runner for one E2E run, and take it down again.
#
#   stack.sh up     — network, containers, seeded database, flows, front proxy
#   stack.sh down   — remove everything; prints each container's log first when the run failed
#
# Spec: docs/superpowers/specs/2026-09-18-e2e-ephemeral-stack.md. The decisions that shape this
# file, so nobody has to rediscover them from the code:
#
#   * The environment of every container is rendered from the product chart (D17), not carried
#     here. A list maintained in nova.ci is a copy that rots — the engine gains a required key,
#     the chart learns it, and this stack keeps booting yesterday's product.
#   * Flows are copied from the stand at boot (D7). The canonical chatbot flow does not transfer
#     a conversation to a team the way the QA set does, proven on the stand on 2026-09-17.
#   * NATS starts before the engine: with campaigns on, the engine awaits it before listening.
#   * One front proxy serves a single origin (D15), because the UI image serves static files and
#     proxies nothing, and the suite derives its API URL from ENV_URL.
#   * Everything runs on the host network, like the DAST bring-up: that is what lets
#     dast_bring_up_nats be reused unchanged rather than parameterised for a bridge network,
#     and a runner VM serves one job at a time, so the fixed ports cannot collide.
#
# Every wait fails loudly with the container's own log. "The image did not come up" with no
# evidence is the failure mode this repository has paid for twice.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${STACK_DIR}/../dast/dast-common.sh"
# The per-repository boot table, sourced rather than copied for the same reason every DAST
# caller reaches it through one file: what an image needs before it will answer is knowledge
# that goes stale in every copy but the one being maintained.
# shellcheck source=/dev/null
. "${STACK_DIR}/../dast/targets.sh"

PREFIX="${E2E_STACK_PREFIX:-e2e}"
# 18080, not 8080: the E2E runner image already runs an nginx bound to 0.0.0.0:8080, found by
# the port guard below on probe 35582984980 after three runs had quietly reported that nginx
# as our own front proxy. Nothing else on the VM contends for this one.
PROXY_PORT="${E2E_PROXY_PORT:-18080}"
ENGINE_PORT=3000; DIALER_PORT=3002; BOTFLOW_PORT=1880; UI_PORT=8000
BOOT_TIMEOUT="${E2E_BOOT_TIMEOUT:-300}"
WORK="${RUNNER_TEMP:-/tmp}/e2e-stack"
# yq is how a rendered ConfigMap becomes an env file; pinned by tag and digest like every other
# tool image here, so a moved tag cannot change what this stack boots with.
YQ_IMAGE="mikefarah/yq:4.44.3"

# This stack's own Node-RED admin, which has to match the bcrypt hashes in
# values.ephemeral.yaml. Not a secret in any useful sense: it admits you to a container on the
# loopback interface of a single-tenant VM, for the length of one run. The suite is handed the
# same pair, so a change here is a change in three places — the failure is loud and named.
BOTFLOW_ADMIN_LOGIN="${BOTFLOW_ADMIN_LOGIN:-support@novatalks.ai}"
BOTFLOW_ADMIN_PASSWORD="${BOTFLOW_ADMIN_PASSWORD:-e2e-ephemeral-not-a-real-secret}"

PG="${PREFIX}-postgres"; REDIS="${PREFIX}-redis"
ENGINE="${PREFIX}-engine"; DIALER="${PREFIX}-dialer"; BOTFLOW="${PREFIX}-botflow"
UI="${PREFIX}-ui"; PROXY="${PREFIX}-proxy"
# nova-nats is the name dast_bring_up_nats gives it; this reuses that helper rather than
# copying its stream setup, so the name comes with it.
ALL_CONTAINERS=("$PROXY" "$UI" "$BOTFLOW" "$DIALER" "$ENGINE" nova-nats "$REDIS" "$PG")

log()  { printf '[stack] %s\n' "$1"; }
fail() { # fail <message> [container]
    printf '::error::%s\n' "$1" >&2
    [ -n "${2:-}" ] && docker logs --tail 60 "$2" 2>&1 | sed 's/^/    /' >&2 || true
    exit 1
}

# curl writes 000 itself when there is no response, and exits non-zero saying so. The `|| true`
# is for set -e and nothing else: appending a second 000 with an `|| echo` makes the value
# "000000", which compares equal to no code at all — that is how the port guard below read a
# free port as occupied on probe 35583343234, with no listener in the ss output beside it.
http_code() { # http_code <url> [timeout-seconds]
    curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-5}" "$1" 2>/dev/null || true
}

wait_http() { # wait_http <name> <url> <container> [timeout-seconds]
    local name="$1" url="$2" container="$3" timeout="${4:-$BOOT_TIMEOUT}" code="" i=0
    for i in $(seq 1 $(( timeout / 2 ))); do
        code="$(http_code "$url")"
        # Any answer at all means it is listening; a 401 or 404 is still an answer, and a
        # health path that returns one is not this script's business to judge.
        [ -n "$code" ] && [ "$code" != "000" ] && { log "$name is up (HTTP $code) after $(( i * 2 ))s"; return 0; }
        # A silent wait and a hang look identical in a job log — that is how the first probe
        # run read as "stuck" while the engine was busy migrating. Every 30s, say how long it
        # has been waiting and what the container itself last said; a container that has
        # stopped saying anything new is the actual signal of a hang.
        if [ $(( i % 15 )) -eq 0 ]; then
            log "$name: waiting $(( i * 2 ))s — last line: $(docker logs --tail 1 "$container" 2>&1 | tr -d '\r' | cut -c1-140)"
        fi
        sleep 2
    done
    fail "$name did not answer $url within ${timeout}s" "$container"
}

render_env() { # render_env <configmap-suffix> <output file>
    local suffix="$1" out="$2"
    docker run --rm -i "$YQ_IMAGE" \
        "select(.kind == \"ConfigMap\" and (.metadata.name | test(\"${suffix}$\"))) | .data | to_entries | .[] | .key + \"=\" + (.value | tostring)" \
        < "${WORK}/rendered.yaml" > "$out"
    [ -s "$out" ] || fail "the chart rendered no ${suffix} ConfigMap — wrong chart_ref or values?"
    log "$(wc -l < "$out" | tr -d ' ') settings for ${suffix}"
}

render_file() { # render_file <configmap-suffix> <key> <output file>
    local suffix="$1" key="$2" out="$3"
    docker run --rm -i "$YQ_IMAGE" \
        "select(.kind == \"ConfigMap\" and (.metadata.name | test(\"${suffix}$\"))) | .data.\"${key}\"" \
        < "${WORK}/rendered.yaml" > "$out"
    [ -s "$out" ] || fail "the chart rendered no ${key} in a ${suffix} ConfigMap"
    log "$(wc -l < "$out" | tr -d ' ') lines of ${key} from ${suffix}"
}

# Sets NR_TOKEN rather than printing it: the mask has to be written to stdout for the runner to
# act on it, so a function that printed both would hand its caller the mask line as well.
NR_TOKEN=""
nr_token() { # nr_token <botflow-url> <user> <password>
    local url="$1" body="${WORK}/nr-auth.json"
    NR_TOKEN=""
    # The password goes through a file, never through curl's argv: a runner is single-tenant
    # but the process list is not the place to put one either way.
    ( umask 077; jq -n --arg u "$2" --arg p "$3" \
        '{client_id:"node-red-admin",grant_type:"password",scope:"*",username:$u,password:$p}' > "$body" )
    NR_TOKEN="$(curl -fsS -X POST "${url}/auth/token" -H 'Content-Type: application/json' \
        -d "@${body}" 2>/dev/null | jq -r '.access_token // empty')"
    rm -f "$body"
    [ -n "$NR_TOKEN" ] || return 1
    # Masked whatever its source, like every other token this repository acquires: the failure
    # paths here print curl output and container logs, and nova.ci is public.
    printf '::add-mask::%s\n' "$NR_TOKEN"
}

copy_flows() { # the stand's own flow document, rewritten for this stack (spec D7)
    # No apostrophe in that message on purpose: bash reopens quoting inside ${var:?word}, so a
    # single quote there silently swallows the rest of the file.
    local src="${E2E_SOURCE_BOTFLOW_URL:?must name the stand Node-RED admin API, e.g. https://host/redbot}"
    : "${E2E_SOURCE_BOTFLOW_LOGIN:?}" "${E2E_SOURCE_BOTFLOW_PASSWORD:?}"
    local origin="${src%/redbot}" project="${E2E_SOURCE_PROJECT:-ntk-dev-e2e-test}"
    local src_token dst_token rev nodes digest

    log "copying flows from ${src}"
    # No fallback document, by decision: a suite that silently ran different chatbot logic is
    # worse than one that did not run. This is also the single thing an ephemeral run still
    # needs the lab for.
    nr_token "$src" "$E2E_SOURCE_BOTFLOW_LOGIN" "$E2E_SOURCE_BOTFLOW_PASSWORD" \
        || fail "could not authenticate to the stand's Node-RED at ${src} — flows are copied from it and there is no fallback"
    src_token="$NR_TOKEN"
    curl -fsS -H "Authorization: Bearer ${src_token}" -H 'Node-RED-API-Version: v2' \
        "${src}/flows" -o "${WORK}/stand-flows.json" \
        || fail "could not read the stand's flows from ${src}/flows"
    jq -e '.flows | length > 0' "${WORK}/stand-flows.json" >/dev/null \
        || fail "the stand returned no flows — refusing to deploy an empty document"

    # The stand's own addresses must not survive into a stack that exists to be independent of
    # it. A receive node left pointing at the lab would have this run creating conversations
    # there; an engine connector would write to its database; and probe 35587666242 found a
    # node addressing ntk-dev-e2e-test-redis, which is the DB holding the stand's own flows.
    #
    # Every in-cluster service name goes to 127.0.0.1, not just the ones in a URL: the first
    # attempt rewrote http://<name>:<port> and missed a bare host field. The ports agree
    # already — engine 3000, botflow 1880, redis 6379 are the same here as in the cluster —
    # so the host alone is the whole substitution. Say which names were found: a guard that
    # stops reporting once it passes teaches nobody what it is protecting against.
    local stand_refs
    # `|| true` on both greps: this file runs under `set -euo pipefail`, where grep finding
    # nothing exits 1, fails the whole pipeline and kills the script — so the leftover check
    # below died silently on exactly the run where it had nothing to report (35587962578).
    stand_refs="$(grep -o -E "${origin}|${project}-[a-z0-9-]+" "${WORK}/stand-flows.json" \
        | sort | uniq -c | sort -rn | awk '{printf "%s×%s ", $1, $2}' || true)"
    log "rewriting stand addresses: ${stand_refs:-none found}"
    sed -e "s|${origin}|http://localhost:${PROXY_PORT}|g" \
        -e "s|${project}-[a-z0-9-]*|127.0.0.1|g" \
        "${WORK}/stand-flows.json" > "${WORK}/flows.json"
    local leftover
    leftover="$(grep -o -E "${origin}|${project}-[a-z0-9]+" "${WORK}/flows.json" | sort -u | tr '\n' ' ' || true)"
    [ -z "$leftover" ] || fail "the copied flows still address the stand: ${leftover}"

    # What was copied, so a red run can be told from a flow change. The digest is of the
    # document as it left the stand, not as rewritten, so it is comparable between runs.
    nodes="$(jq '.flows | length' "${WORK}/stand-flows.json")"
    digest="$(jq -cS '.flows' "${WORK}/stand-flows.json" | shasum -a 256 2>/dev/null | cut -c1-12)" \
        || digest="$(jq -cS '.flows' "${WORK}/stand-flows.json" | sha256sum | cut -c1-12)"
    log "${nodes} nodes, digest ${digest}"

    nr_token "http://127.0.0.1:${BOTFLOW_PORT}/redbot" "$BOTFLOW_ADMIN_LOGIN" "$BOTFLOW_ADMIN_PASSWORD" \
        || fail "could not authenticate to this stack's own Node-RED — adminAuth needs a bcrypt hash in the values, not a plain string" "$BOTFLOW"
    dst_token="$NR_TOKEN"
    rev="$(curl -fsS -H "Authorization: Bearer ${dst_token}" -H 'Node-RED-API-Version: v2' \
        "http://127.0.0.1:${BOTFLOW_PORT}/redbot/flows" | jq -r '.rev // empty')"
    jq --arg rev "$rev" '{rev: $rev, flows: .flows}' "${WORK}/flows.json" > "${WORK}/deploy.json"
    curl -fsS -X POST "http://127.0.0.1:${BOTFLOW_PORT}/redbot/flows" \
        -H "Authorization: Bearer ${dst_token}" -H 'Content-Type: application/json' \
        -H 'Node-RED-API-Version: v2' -H 'Node-RED-Deployment-Type: full' \
        -d "@${WORK}/deploy.json" -o "${WORK}/deploy-result.json" \
        || fail "deploying the flows failed: $(head -c 300 "${WORK}/deploy-result.json" 2>/dev/null)" "$BOTFLOW"

    # Slot 1's telegram route is the proof the deploy took: redbot registers a webhook when its
    # config node starts, and an unregistered route answers 404 where a registered one answers
    # 200. The rest of the slots are the suite's own reconcile to make, per worker.
    local route="http://127.0.0.1:${BOTFLOW_PORT}/redbot/telegram/1" code=""
    for _ in $(seq 1 30); do
        code="$(http_code "$route")"
        [ -n "$code" ] && [ "$code" != "404" ] && [ "$code" != "000" ] && break
        sleep 2
    done
    [ "$code" != "404" ] && [ "$code" != "000" ] \
        || fail "the channel routes never came up after the deploy (/telegram/1 answers ${code})" "$BOTFLOW"
    log "flows deployed, /telegram/1 answers ${code}"
}

up() {
    mkdir -p "$WORK"
    # The origin is written in two places — here and in the chart values, which build every
    # URL the UI, the engine and the channel webhooks hand out. They have to agree, and a
    # mismatch would surface as a webhook posted to a port nobody serves, far from its cause.
    grep -q "localhost:${PROXY_PORT}" "${STACK_DIR}/values.ephemeral.yaml" \
        || fail "values.ephemeral.yaml does not name localhost:${PROXY_PORT} — the origin and the proxy port have drifted apart"
    : "${CHART_PACKAGE:=ghcr.io/novaitdevteam/novatalks.charts/novatalks-platform}"
    : "${CHART_VERSION:?CHART_VERSION must name a published chart version, e.g. 5.4.7}"
    : "${ENGINE_IMAGE:?}" "${UI_IMAGE:?}" "${BOTFLOW_IMAGE:?}" "${DIALER_IMAGE:?}"

    # The chart is a published OCI package, not a git checkout: a version pins configuration
    # the way an image tag pins code, and the stand's own release names the exact one (the lab
    # ran novatalks-platform-5.4.7). Rendering needs no access to the chart's source.
    log "rendering ${CHART_PACKAGE}:${CHART_VERSION}"
    helm template e2e "oci://${CHART_PACKAGE}" --version "$CHART_VERSION" \
        -f "${STACK_DIR}/values.ephemeral.yaml" > "${WORK}/rendered.yaml" \
        || fail "helm template failed — chart ${CHART_VERSION} and values.ephemeral.yaml have diverged"
    render_env "engine-config"      "${WORK}/engine.env"
    render_env "botflow-config-env" "${WORK}/botflow.env"
    render_env "ui-config"          "${WORK}/ui.env"

    log "postgres"
    # Durability off, deliberately: this database is created, migrated, used by one suite and
    # destroyed with the runner, so an fsync per commit buys nothing and costs a lot — the
    # engine's 291 migrations were still running at 900s on a Hetzner disk. A crash here means
    # the run is over anyway; there is nothing to recover to.
    docker run -d --name "$PG" --network host \
        -e POSTGRES_USER=novatalks -e POSTGRES_PASSWORD=e2e-local -e POSTGRES_DB=novatalks \
        postgres:17.9-trixie \
        -c fsync=off -c synchronous_commit=off -c full_page_writes=off \
        >/dev/null || fail "postgres refused to start"
    for _ in $(seq 1 30); do
        docker exec "$PG" pg_isready -U novatalks >/dev/null 2>&1 && break
        sleep 2
    done
    docker exec "$PG" pg_isready -U novatalks >/dev/null 2>&1 \
        || fail "postgres never became ready" "$PG"
    # The dialer keeps its own database on the same server, exactly as the chart deploys it.
    docker exec "$PG" psql -U novatalks -d novatalks -c 'create database dialer' >/dev/null 2>&1 || true

    log "redis"
    docker run -d --name "$REDIS" --network host redis:8 >/dev/null || fail "redis refused to start"

    log "nats"
    # Shared with the DAST bring-up rather than copied: the 'campaign' stream the dialer's
    # client asks for at startup is easy to forget, and a JetStream without it still answers
    # "no stream matches subject".
    dast_bring_up_nats fail "${WORK}/nats-stream.log"

    log "engine ${ENGINE_IMAGE}"
    docker run -d --name "$ENGINE" --network host --env-file "${WORK}/engine.env" \
        -e DATABASE_HOST=127.0.0.1 -e DATABASE_PORT=5432 \
        -e DATABASE_USERNAME=novatalks -e DATABASE_PASSWORD=e2e-local -e DATABASE_NAME=novatalks \
        -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6379 \
        -e NATS_SERVERS=127.0.0.1:4222 \
        -e FILE_DRIVER="${FILE_DRIVER:-s3}" \
        -e AWS_S3_ENDPOINT="${AWS_S3_ENDPOINT:-}" -e AWS_S3_BUCKET="${AWS_S3_BUCKET:-}" \
        -e AWS_S3_ACCESS_KEY="${AWS_S3_ACCESS_KEY:-}" -e AWS_S3_SECRET="${AWS_S3_SECRET:-}" \
        -e AWS_S3_REGION="${AWS_S3_REGION:-eeur}" -e AWS_S3_FORCE_PATH_STYLE=true \
        "$ENGINE_IMAGE" >/dev/null || fail "the engine container refused to start"
    # Campaigns are on, and they are on in the values rather than as an -e here: the engine
    # awaits a JetStream consumer before it listens, and the chart renders the keys that
    # build one — NATS_DURABLE, NATS_DELIVER_TO, NATS_SUBJECTS — only under
    # engine.nats.enabled. Forcing the feature past that flag builds a consumer out of
    # undefined and never reaches app.listen(). NATS_SERVERS below is a host override, which
    # is all this script is allowed to change about a rendered environment.
    #
    # Migrations and seeds run from the engine's own entrypoint; /readyz is the completion
    # signal, which is why nothing here runs a setup command of its own. It gets its own,
    # longer budget because that work is real: 291 migrations and the full seed set against an
    # empty database, which the first probe run was still in the middle of at 300s.
    #
    # An engine that prints nothing after the seeder's last line is not a slow engine: main.ts
    # creates the app with bufferLogs and only installs the real logger after the microservice
    # is listening, and its uncaughtException handler logs into that same buffer — so a
    # bootstrap that throws keeps the process alive and silent. Silence here means a failure
    # that was swallowed, never progress.
    wait_http "engine" "http://127.0.0.1:${ENGINE_PORT}/readyz" "$ENGINE" "${E2E_ENGINE_BOOT_TIMEOUT:-900}"

    log "stand settings the seeds do not make"
    # Each of these has already cost a red suite: an expired trial hides login behind a promo
    # banner, a non-English locale fails every asserted string, and a one-agent licence fails
    # the second test that creates one.
    docker exec "$PG" psql -U novatalks -d novatalks -v ON_ERROR_STOP=1 -c "
        update accounts set active_until = now() + interval '5 years',
                            locale = 'en',
                            limits = jsonb_set(limits::jsonb, '{users}', '100'),
                            updated_at = now()
        where id = 1" >/dev/null || fail "could not apply the stand settings" "$PG"
    # BotFlow presents this token on every call; with no agent_bots row carrying it the engine
    # answers 401 a minute forever.
    bot_token="$(grep -E '^NOVATALKS_BOTAGENT_TOKEN=' "${WORK}/botflow.env" | cut -d= -f2-)"
    bot_hook="http://127.0.0.1:${BOTFLOW_PORT}/redbot/novatalks-botagent/1"
    docker exec "$PG" psql -U novatalks -d novatalks -v ON_ERROR_STOP=1 -c "
        update agent_bots set outgoing_url = '${bot_hook}' where account_id = 1;
        insert into access_tokens (owner_type, owner_id, token, created_at, updated_at)
        select 'AgentBot', id, '${bot_token}', now(), now() from agent_bots where account_id = 1
        limit 1" >/dev/null || fail "could not seed the AgentBot token" "$PG"

    log "dialer ${DIALER_IMAGE}"
    # Its boot environment — HEALTH_ENABLED, the NATS keys, the S3 dummies — comes from the
    # api-scan arm of the target table, which is the one place that knows it. NATS_DELIVER_TO
    # is the line that matters: without it the dialer connects, finds the stream, and dies
    # building a push consumer with no deliver_subject. A live pentest run paid for that once.
    dast_resolve_target novatalks.dialer api
    printf '%s\n' "$DT_EXTRA_ENV" > "${WORK}/dialer.env"
    # APP_PORT, not PORT: app.config.ts validates APP_PORT with a Joi default of 3006, so PORT
    # sets nothing and the health poll would wait out its budget against a port nobody serves.
    # And no FILE_DRIVER: multer-config.service.ts's storages map holds one entry, s3, so
    # FILE_DRIVER=local indexes it to undefined and calls it — the TypeError that killed this
    # container on probe run 35580442650. The default is already s3 and the dummies above feed it.
    docker run -d --name "$DIALER" --network host --env-file "${WORK}/dialer.env" \
        -e NODE_ENV=production -e APP_PORT="${DIALER_PORT}" \
        -e DATABASE_HOST=127.0.0.1 -e DATABASE_PORT=5432 \
        -e DATABASE_USERNAME=novatalks -e DATABASE_PASSWORD=e2e-local -e DATABASE_NAME=dialer \
        -e DATABASE_URL="postgresql://novatalks:e2e-local@127.0.0.1:5432/dialer" \
        -e NATS_SERVERS=127.0.0.1:4222 \
        "$DIALER_IMAGE" >/dev/null || fail "the dialer container refused to start"
    wait_http "dialer" "http://127.0.0.1:${DIALER_PORT}/readyz" "$DIALER"

    log "botflow ${BOTFLOW_IMAGE}"
    # settings.js comes from the chart too, not from the image: the image's own leaves
    # httpAdminRoot commented out, so Node-RED serves everything from / and every /redbot
    # route — the admin API the flows are deployed through, and every channel webhook —
    # is a 404. The chart mounts this same file at this same path (multinode sync is on in
    # our values, so it is the sync ConfigMap), which is what makes the stand's flows and
    # this stack's agree on where they live.
    render_file "botflow-sync-config" "settings.js" "${WORK}/botflow-settings.js"
    docker run -d --name "$BOTFLOW" --network host --env-file "${WORK}/botflow.env" \
        -v "${WORK}/botflow-settings.js:/opt/nova.botflow/config/settings.js:ro" \
        -e BF_REDIS_HOST=127.0.0.1 -e BF_REDIS_PORT=6379 -e BF_REDIS_DB=15 \
        -e NOVATALKS_ENGINE_URL="http://127.0.0.1:${ENGINE_PORT}" \
        -e NOVATALKS_BOTAGENT_WEBHOOK="$bot_hook" \
        "$BOTFLOW_IMAGE" >/dev/null || fail "the botflow container refused to start"
    wait_http "botflow" "http://127.0.0.1:${BOTFLOW_PORT}/redbot/" "$BOTFLOW"
    # Node-RED answers on every path, so "it answered" is not evidence here the way it is on
    # a health endpoint: a 404 on the admin root is what a botflow running the image's own
    # settings.js looks like, and it read as up for one whole probe run.
    if [ "$(http_code "http://127.0.0.1:${BOTFLOW_PORT}/redbot/")" = "404" ]; then
        fail "botflow answers 404 on /redbot/ — settings.js did not take, so httpAdminRoot is still '/'" "$BOTFLOW"
    fi

    copy_flows

    log "ui ${UI_IMAGE}"
    docker run -d --name "$UI" --network host --env-file "${WORK}/ui.env" \
        -e VITE_APP_WEBSOCKET_URL="http://localhost:${PROXY_PORT}" \
        "$UI_IMAGE" >/dev/null || fail "the ui container refused to start"
    wait_http "ui" "http://127.0.0.1:${UI_PORT}/" "$UI"

    log "front proxy"
    # Nothing may already hold the port, and "something answers on it" is not the same thing
    # as "our proxy is up": probe 35582573611 read nginx's own log and found
    # `bind() to 0.0.0.0:8080 failed (98: Address in use)` — the stranger already there
    # answered 200 on / and 404 on every route, which is indistinguishable from a working
    # proxy from the outside, and had been passing this wait for three runs.
    if [ "$(http_code "http://127.0.0.1:${PROXY_PORT}/" 3)" != "000" ]; then
        printf '::error::something already answers on port %s — the front proxy cannot bind it\n' "$PROXY_PORT" >&2
        (ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null) | grep ":${PROXY_PORT}" >&2 || true
        docker ps --format '    {{.Names}}  {{.Image}}  {{.Ports}}' >&2
        exit 1
    fi
    # The lab's Traefik route table, copied rather than invented: a route the stand has and the
    # runner lacks is a test that passes in one place and fails in the other for no product
    # reason. /redbot must come before /, and the dialer prefix before the engine's /api/.
    cat > "${WORK}/proxy.conf" <<EOF
server {
    listen ${PROXY_PORT};
    client_max_body_size 64m;
    location /redbot { proxy_pass http://127.0.0.1:${BOTFLOW_PORT}; ${PROXY_HEADERS:-} }
    location /api/v1/dialer/ { proxy_pass http://127.0.0.1:${DIALER_PORT}; }
    location /api/ { proxy_pass http://127.0.0.1:${ENGINE_PORT}; }
    location /auth/ { proxy_pass http://127.0.0.1:${ENGINE_PORT}; }
    location /store/ { proxy_pass http://127.0.0.1:${ENGINE_PORT}; }
    location /widget { proxy_pass http://127.0.0.1:${ENGINE_PORT}; }
    location /api-docs { proxy_pass http://127.0.0.1:${ENGINE_PORT}; }
    location /webwidget-docs { proxy_pass http://127.0.0.1:${ENGINE_PORT}; }
    location /ws { proxy_pass http://127.0.0.1:${ENGINE_PORT}; proxy_http_version 1.1;
                   proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; }
    location /webrtc-ws { proxy_pass http://127.0.0.1:${ENGINE_PORT}; proxy_http_version 1.1;
                          proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; }
    location / { proxy_pass http://127.0.0.1:${UI_PORT}; }
}
EOF
    docker run -d --name "$PROXY" --network host \
        -v "${WORK}/proxy.conf:/etc/nginx/conf.d/default.conf:ro" \
        nginx:1.27-alpine >/dev/null || fail "the proxy container refused to start"
    wait_http "proxy" "http://127.0.0.1:${PROXY_PORT}/" "$PROXY"
    # Answering is not routing. botflow is known to answer 200 on its own port by now, so the
    # same path through the proxy must too — that is the one check that distinguishes our
    # nginx, with the stand's route table, from anything else listening on this port.
    proxy_code="$(http_code "http://127.0.0.1:${PROXY_PORT}/redbot/")"
    if [ "$proxy_code" != "200" ]; then
        fail "the proxy answers ${proxy_code} on /redbot/ while botflow answers 200 on its own port — it is not routing" "$PROXY"
    fi

    # Hand the run the address to point the suite at, rather than have the workflow repeat the
    # port: it already lives here and in the chart values, and a third copy is the one that
    # would be missed. The Node-RED credentials go with it for the same reason — the suite
    # needs them and they are fixed fakes, not secrets.
    if [ -n "${GITHUB_ENV:-}" ]; then
        {
            printf 'E2E_STACK_ORIGIN=http://localhost:%s\n' "$PROXY_PORT"
            printf 'E2E_STACK_BOTFLOW_LOGIN=%s\n' "$BOTFLOW_ADMIN_LOGIN"
            printf 'E2E_STACK_BOTFLOW_PASSWORD=%s\n' "$BOTFLOW_ADMIN_PASSWORD"
        } >> "$GITHUB_ENV"
    fi
    log "stack is up on http://localhost:${PROXY_PORT}"
}

down() {
    # Unconditional, and the logs come first: a stack nobody can inspect afterwards is worse
    # than no stack. E2E_STACK_FAILED is set by the caller when the suite went red.
    if [ "${E2E_STACK_FAILED:-0}" = "1" ]; then
        for c in "${ALL_CONTAINERS[@]}"; do
            docker inspect "$c" >/dev/null 2>&1 || continue
            printf '\n===== %s =====\n' "$c"
            docker logs --tail 200 "$c" 2>&1 || true
        done
    fi
    docker rm -f "${ALL_CONTAINERS[@]}" >/dev/null 2>&1 || true
    rm -rf "$WORK" >/dev/null 2>&1 || true
    # Say so when something survived, rather than reporting a teardown that did not happen.
    # A runner is reused: a container left holding 3000 or 5432 meets the next job as a boot
    # failure in whatever runs there next, with nothing pointing back here.
    local left
    left="$(docker ps -a --filter "name=^${PREFIX}-" --filter 'name=^nova-nats$' --format '{{.Names}}' | tr '\n' ' ')"
    if [ -n "$left" ]; then
        printf '::error::teardown left containers behind: %s\n' "$left" >&2
        exit 1
    fi
    log "stack is down, nothing left behind"
}

case "${1:-}" in
    up)   up ;;
    down) down ;;
    *)    echo "usage: stack.sh up|down" >&2; exit 2 ;;
esac
