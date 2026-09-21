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

PREFIX="${E2E_STACK_PREFIX:-e2e}"
PROXY_PORT="${E2E_PROXY_PORT:-8080}"
ENGINE_PORT=3000; DIALER_PORT=3002; BOTFLOW_PORT=1880; UI_PORT=8000
BOOT_TIMEOUT="${E2E_BOOT_TIMEOUT:-300}"
WORK="${RUNNER_TEMP:-/tmp}/e2e-stack"
# yq is how a rendered ConfigMap becomes an env file; pinned by tag and digest like every other
# tool image here, so a moved tag cannot change what this stack boots with.
YQ_IMAGE="mikefarah/yq:4.44.3"

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

wait_http() { # wait_http <name> <url> <container> [timeout-seconds]
    local name="$1" url="$2" container="$3" timeout="${4:-$BOOT_TIMEOUT}" code="" i=0
    for i in $(seq 1 $(( timeout / 2 ))); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)"
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

up() {
    mkdir -p "$WORK"
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
        -e APPLICATION_CAMPAIGN_ENABLE=true \
        -e FILE_DRIVER="${FILE_DRIVER:-s3}" \
        -e AWS_S3_ENDPOINT="${AWS_S3_ENDPOINT:-}" -e AWS_S3_BUCKET="${AWS_S3_BUCKET:-}" \
        -e AWS_S3_ACCESS_KEY="${AWS_S3_ACCESS_KEY:-}" -e AWS_S3_SECRET="${AWS_S3_SECRET:-}" \
        -e AWS_S3_REGION="${AWS_S3_REGION:-eeur}" -e AWS_S3_FORCE_PATH_STYLE=true \
        "$ENGINE_IMAGE" >/dev/null || fail "the engine container refused to start"
    # Migrations and seeds run from the engine's own entrypoint; /readyz is the completion
    # signal, which is why nothing here runs a setup command of its own. It gets its own,
    # longer budget because that work is real: 291 migrations and the full seed set against an
    # empty database, which the first probe run was still in the middle of at 300s.
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
    docker run -d --name "$DIALER" --network host \
        -e NODE_ENV=production -e PORT="${DIALER_PORT}" -e HEALTH_ENABLED=true \
        -e DATABASE_HOST=127.0.0.1 -e DATABASE_PORT=5432 \
        -e DATABASE_USERNAME=novatalks -e DATABASE_PASSWORD=e2e-local -e DATABASE_NAME=dialer \
        -e DATABASE_URL="postgresql://novatalks:e2e-local@127.0.0.1:5432/dialer" \
        -e NATS_SERVERS=127.0.0.1:4222 -e NATS_SUBJECTS=campaign \
        -e FILE_DRIVER=local \
        -e AWS_S3_ACCESS_KEY_ID=e2e-dummy-not-a-real-key -e AWS_S3_SECRET_ACCESS_KEY=e2e-dummy-not-a-real-key \
        -e AWS_S3_ENDPOINT=http://s3.example.invalid -e AWS_S3_REGION=eeur -e AWS_S3_BUCKET=e2e-dummy \
        "$DIALER_IMAGE" >/dev/null || fail "the dialer container refused to start"
    wait_http "dialer" "http://127.0.0.1:${DIALER_PORT}/readyz" "$DIALER"

    log "botflow ${BOTFLOW_IMAGE}"
    docker run -d --name "$BOTFLOW" --network host --env-file "${WORK}/botflow.env" \
        -e BF_REDIS_HOST=127.0.0.1 -e BF_REDIS_PORT=6379 -e BF_REDIS_DB=15 \
        -e NOVATALKS_ENGINE_URL="http://127.0.0.1:${ENGINE_PORT}" \
        -e NOVATALKS_BOTAGENT_WEBHOOK="$bot_hook" \
        "$BOTFLOW_IMAGE" >/dev/null || fail "the botflow container refused to start"
    wait_http "botflow" "http://127.0.0.1:${BOTFLOW_PORT}/redbot/" "$BOTFLOW"

    log "ui ${UI_IMAGE}"
    docker run -d --name "$UI" --network host --env-file "${WORK}/ui.env" \
        -e VITE_APP_WEBSOCKET_URL="http://localhost:${PROXY_PORT}" \
        "$UI_IMAGE" >/dev/null || fail "the ui container refused to start"
    wait_http "ui" "http://127.0.0.1:${UI_PORT}/" "$UI"

    log "front proxy"
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
    log "stack is down"
}

case "${1:-}" in
    up)   up ;;
    down) down ;;
    *)    echo "usage: stack.sh up|down" >&2; exit 2 ;;
esac
