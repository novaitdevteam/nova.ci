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
# Named for this stack, not generically: `BOTFLOW_ADMIN_LOGIN` is what the *suite* calls the
# stand's credentials, and anything that sources the tests repository's .env — local.sh does —
# would otherwise hand this container somebody else's password and get a 401 it cannot explain.
STACK_BF_LOGIN="${E2E_STACK_BF_LOGIN:-support@novatalks.ai}"
STACK_BF_PASSWORD="${E2E_STACK_BF_PASSWORD:-e2e-ephemeral-not-a-real-secret}"

# The helm release name, which is what every rendered in-cluster hostname is built from.
RELEASE="${E2E_HELM_RELEASE:-e2e}"

PG="${PREFIX}-postgres"; REDIS="${PREFIX}-redis"
ENGINE="${PREFIX}-engine"; DIALER="${PREFIX}-dialer"; BOTFLOW="${PREFIX}-botflow"
UI="${PREFIX}-ui"; PROXY="${PREFIX}-proxy"
# nova-nats is the name dast_bring_up_nats gives it; this reuses that helper rather than
# copying its stream setup, so the name comes with it.
ALL_CONTAINERS=("$PROXY" "$UI" "$BOTFLOW" "$DIALER" "$ENGINE" nova-nats "$REDIS" "$PG" "$PREFIX-probe")

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
# Every probe runs from inside the stack's own network, through a small container kept alive
# for the purpose, rather than with the host's curl. On a runner the two are the same thing;
# on a Mac they are not — `--network host` puts the containers in Docker's Linux VM, whose
# ports the host cannot reach, so the host's curl sees nothing and every wait expires against
# a stack that is running perfectly. One path for both, deliberately: today produced three
# separate faults that were invisible in one environment and obvious in the other.
PROBE="${PREFIX}-probe"
PROBE_IMAGE="curlimages/curl:8.11.1"

probe_up() {
    docker inspect "$PROBE" >/dev/null 2>&1 && return 0
    docker run -d --name "$PROBE" --network host --entrypoint sleep "$PROBE_IMAGE" infinity \
        >/dev/null || fail "could not start the probe container"
}

http_code() { # http_code <url> [timeout-seconds]
    # -k because the front proxy's certificate is generated per run and signed by nothing.
    # This is a health check against our own containers, not a trust decision.
    docker exec "$PROBE" curl -sk -o /dev/null -w '%{http_code}' --max-time "${2:-5}" "$1" 2>/dev/null || true
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

# Reads one key out of a rendered env file, empty when it is not there. A plain
# `grep ... | cut` cannot be used inline: this script runs under `set -euo pipefail`, where a
# grep that matches nothing exits 1, pipefail carries that to the pipeline and set -e ends the
# run — with no message, because nothing called fail. That has now happened three times in one
# day (the flow leftover check, and DEFAULT_ADMIN_USER, which the chart does not render at
# all), so it lives in one place with the `|| true` that makes it safe.
env_value() { # env_value <key> <env-file>
    grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# `docker run -d` succeeds as soon as the container is *created*. A container that dies a
# second later — a port already taken, an entrypoint that exits — still returns an id, so
# `|| fail` never fires and the script carries on to the next component, which then fails for
# a reason that has nothing to do with its own configuration. This repository has paid for
# that shape once already (the CloudNativePG image whose entrypoint was bash, in CLAUDE.md);
# it cost an engine "boot failure" here that was really a redis with no port to bind.
started() { # started <container> <human name>
    sleep 1
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ] \
        || fail "$2 exited immediately after starting" "$1"
}

render_env() { # render_env <configmap-suffix> <output file>
    local suffix="$1" out="$2"
    docker run --rm -i "$YQ_IMAGE" \
        "select(.kind == \"ConfigMap\" and (.metadata.name | test(\"${suffix}$\"))) | .data | to_entries | .[] | .key + \"=\" + (.value | tostring)" \
        < "${WORK}/rendered.yaml" > "$out"
    [ -s "$out" ] || fail "the chart rendered no ${suffix} ConfigMap — wrong chart_ref or values?"
    log "$(wc -l < "$out" | tr -d ' ') settings for ${suffix}"
}

# The chart renders for a cluster, where every service is an in-cluster DNS name. That does
# not hold on a runner, where the whole stack shares the host network. The https URLs are
# left alone on purpose: the front proxy terminates TLS here exactly as Traefik does there,
# so the scheme the chart renders is already the right one. Rewriting the
# rendered files is the same move copy_flows makes on the flow document, and for the same
# reason — a -e per key only covers the keys somebody remembered. Comparing the lab's render
# with this one on 2026-09-21 found four that nobody had: CONTACT_CHECK_ENDPOINT,
# NOVATALKS_BOTFLOW_HOST, DIALER_SERVICE_URL and BF_CONFIG_BOTFLOW_URL.
#
# Only a name in host position is touched — followed by a colon, a slash or the end of the
# value — so NATS_NAME=e2e-engine-listener, which is an identifier and not an address, is
# left alone. The dialer moves port as well as host: the chart gives it 3000, which the
# engine already holds here.
localise_env() { # localise_env <env-file>
    local file="$1" before after
    before="$(grep -cE "${RELEASE}-(engine|botflow|dialer|postgres|redis)" "$file" || true)"
    # Written to a temp file rather than with `sed -i`: BSD sed reads the next argument as a
    # backup suffix, so `sed -i -E` makes -E the suffix and the expression is parsed as
    # something else entirely. Only GNU sed runs on the runner, but a script that cannot be
    # run on the machine it is written on is a script that gets debugged through CI.
    sed -E \
        -e "s#${RELEASE}-dialer:3000#${RELEASE}-dialer:${DIALER_PORT}#g" \
        -e "s#${RELEASE}-(engine|botflow|dialer|postgres|redis)(\.[a-z0-9.-]+)?(:|/|\$)#127.0.0.1\3#g" \
        "$file" > "${file}.localised"
    mv "${file}.localised" "$file"
    after="$(grep -cE "${RELEASE}-(engine|botflow|dialer|postgres|redis)" "$file" || true)"
    log "$(basename "$file"): localised $(( before - after )) cluster address(es), $after left as identifiers"
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
    # Through the probe, like every other request: one of the two Node-REDs this is called
    # for is inside the stack's network. The body goes in on stdin, so the password is not in
    # an argument list on either side.
    NR_TOKEN="$(docker exec -i "$PROBE" curl -fsS -X POST "${url}/auth/token" \
        -H 'Content-Type: application/json' -d @- < "$body" 2>/dev/null \
        | jq -r '.access_token // empty')"
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
    local src_token dst_token rev nodes digest cache

    # Normally copied from the stand (D7): no *silent* fallback, ever, because a suite that ran
    # different chatbot logic without saying so is worse than one that did not run.
    #
    # E2E_FLOWS_FILE is the not-silent exception, and it exists because the stand being down
    # stops every ephemeral run, local and CI — which it did on 2026-09-21. Naming a file is a
    # deliberate act, and the run says loudly what it used and how old it is, so a red run can
    # still be told from a flow change. It is never chosen automatically: if the stand cannot
    # be read and no file was named, the run fails, exactly as before.
    if [ -n "${E2E_FLOWS_FILE:-}" ]; then
        [ -f "$E2E_FLOWS_FILE" ] || fail "E2E_FLOWS_FILE names ${E2E_FLOWS_FILE}, which does not exist"
        cp "$E2E_FLOWS_FILE" "${WORK}/stand-flows.json"
        printf '::warning::flows came from %s (last modified %s), not from %s — this run does not reflect the stand current flows\n' \
            "$E2E_FLOWS_FILE" "$(date -r "$E2E_FLOWS_FILE" '+%Y-%m-%d %H:%M' 2>/dev/null || echo unknown)" "$src" >&2
        log "flows from a named file, NOT from the stand"
    else
        log "copying flows from ${src}"
        nr_token "$src" "$E2E_SOURCE_BOTFLOW_LOGIN" "$E2E_SOURCE_BOTFLOW_PASSWORD" \
            || fail "could not authenticate to the stand's Node-RED at ${src} — flows are copied from it, and E2E_FLOWS_FILE was not set"
        src_token="$NR_TOKEN"
        docker exec "$PROBE" curl -fsS -H "Authorization: Bearer ${src_token}" \
            -H 'Node-RED-API-Version: v2' "${src}/flows" > "${WORK}/stand-flows.json" \
            || fail "could not read the stand's flows from ${src}/flows"
        # Keep what was copied, so a later run has something it can be pointed at deliberately.
        cache="${E2E_FLOWS_CACHE:-$HOME/.cache/nova-e2e}"
        mkdir -p "$cache" && cp "${WORK}/stand-flows.json" "${cache}/flows-latest.json" 2>/dev/null || true
    fi
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
    sed -e "s|${origin}|https://localhost:${PROXY_PORT}|g" \
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

    nr_token "http://127.0.0.1:${BOTFLOW_PORT}/redbot" "$STACK_BF_LOGIN" "$STACK_BF_PASSWORD" \
        || fail "could not authenticate to this stack's own Node-RED — adminAuth needs a bcrypt hash in the values, not a plain string" "$BOTFLOW"
    dst_token="$NR_TOKEN"
    rev="$(docker exec "$PROBE" curl -fsS -H "Authorization: Bearer ${dst_token}" \
        -H 'Node-RED-API-Version: v2' "http://127.0.0.1:${BOTFLOW_PORT}/redbot/flows" \
        | jq -r '.rev // empty')"
    jq --arg rev "$rev" '{rev: $rev, flows: .flows}' "${WORK}/flows.json" > "${WORK}/deploy.json"
    docker exec -i "$PROBE" curl -fsS -X POST "http://127.0.0.1:${BOTFLOW_PORT}/redbot/flows" \
        -H "Authorization: Bearer ${dst_token}" -H 'Content-Type: application/json' \
        -H 'Node-RED-API-Version: v2' -H 'Node-RED-Deployment-Type: full' \
        -d @- < "${WORK}/deploy.json" > "${WORK}/deploy-result.json" \
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
    helm template "$RELEASE" "oci://${CHART_PACKAGE}" --version "$CHART_VERSION" \
        -f "${STACK_DIR}/values.ephemeral.yaml" > "${WORK}/rendered.yaml" \
        || fail "helm template failed — chart ${CHART_VERSION} and values.ephemeral.yaml have diverged"
    render_env "engine-config"      "${WORK}/engine.env"
    render_env "botflow-config-env" "${WORK}/botflow.env"
    render_env "ui-config"          "${WORK}/ui.env"
    localise_env "${WORK}/engine.env"
    localise_env "${WORK}/botflow.env"
    localise_env "${WORK}/ui.env"

    probe_up

    # The proxy's certificate, generated here rather than next to the proxy because the engine
    # and botflow are started long before it and both have to trust it: every channel webhook
    # the chart renders is an https://localhost:${PROXY_PORT} URL, so the engine posts a bot's
    # reply to the client through this proxy and Node-RED's own flows call it the same way.
    # Without this the engine logs `Could not send webhook message ...: self-signed certificate`
    # for every outgoing message and marks it `failed`, which reads downstream as the product
    # losing messages. Chromium does not read NODE_EXTRA_CA_CERTS and is told to ignore
    # certificate errors in playwright.config.ts instead. See the proxy section for why TLS.
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -keyout "${WORK}/proxy.key" -out "${WORK}/proxy.crt" \
        -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        >/dev/null 2>&1 || fail "could not generate the proxy certificate"

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
    started "$PG" "postgres"
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
    started "$REDIS" "redis"

    log "nats"
    # Shared with the DAST bring-up rather than copied: the 'campaign' stream the dialer's
    # client asks for at startup is easy to forget, and a JetStream without it still answers
    # "no stream matches subject".
    dast_bring_up_nats fail "${WORK}/nats-stream.log"

    # Read before the engine starts, because the seeder needs one of them. The seeds create
    # the AgentBot *and* a token for it, from AGENTBOT_INBOX_TOKEN or a random value when
    # that is unset — and the chart never renders it, so on a fresh database the engine ends
    # up signing its calls to BotFlow with a token BotFlow has never heard of. BotFlow then
    # ignores every agent-bot call in silence: the conversation is created, the bot is asked,
    # nothing answers, and the suite waits for an offer that cannot come.
    bot_token="$(env_value NOVATALKS_BOTAGENT_TOKEN "${WORK}/botflow.env")"
    engine_token="$(env_value NOVATALKS_ENGINE_TOKEN "${WORK}/botflow.env")"
    # The engine calls the dialer with this and the dialer accepts it because it is in its
    # API_ACCESS_TOKENS — the env-token path targets.sh documents for the DAST api-scan. Both
    # sides are given the same generated value, which avoids the ordering problem the stand
    # has: there the dialer's own bootstrap seeds a random token and the engine has to be
    # upgraded a second time to learn it. Nothing is written to the dialer's database.
    dialer_token="$(openssl rand -hex 24)"
    printf '::add-mask::%s\n' "$dialer_token"
    [ -n "$bot_token" ] && [ -n "$engine_token" ] \
        || fail "the chart rendered no NOVATALKS_BOTAGENT_TOKEN / NOVATALKS_ENGINE_TOKEN for BotFlow"

    log "engine ${ENGINE_IMAGE}"
    docker run -d --name "$ENGINE" --network host --env-file "${WORK}/engine.env" \
        -v "${WORK}/proxy.crt:/etc/e2e-proxy-ca.crt:ro" \
        -e NODE_EXTRA_CA_CERTS=/etc/e2e-proxy-ca.crt \
        -e AGENTBOT_INBOX_TOKEN="$bot_token" \
        -e DIALER_SERVICE_TOKEN="$dialer_token" \
        -e DATABASE_HOST=127.0.0.1 -e DATABASE_PORT=5432 \
        -e DATABASE_USERNAME=novatalks -e DATABASE_PASSWORD=e2e-local -e DATABASE_NAME=novatalks \
        -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6379 \
        -e NATS_SERVERS=127.0.0.1:4222 \
        -e FILE_DRIVER="${FILE_DRIVER:-s3}" \
        -e AWS_S3_ENDPOINT="${AWS_S3_ENDPOINT:-}" -e AWS_S3_BUCKET="${AWS_S3_BUCKET:-}" \
        -e AWS_S3_ACCESS_KEY="${AWS_S3_ACCESS_KEY:-}" -e AWS_S3_SECRET="${AWS_S3_SECRET:-}" \
        -e AWS_S3_REGION="${AWS_S3_REGION:-eeur}" -e AWS_S3_FORCE_PATH_STYLE=true \
        "$ENGINE_IMAGE" >/dev/null || fail "the engine container refused to start"
    started "$ENGINE" "the engine"
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
    #
    # enableAutomaticAgentAssignment is the fourth, and it is the engine's own seed default
    # (`seeds.service.ts`: false). With it off, a conversation handed to a team is only ever
    # added to the queue — `action.service.ts` takes the else arm — and the queue is drained
    # by nothing a single-agent run produces. The first message of a spec still alerts,
    # because the chatbot's transfer forces an assignment; the second sits `open/inqueue`
    # with the agent `online/Idle` beside it and the spec fails on an alert that never rings.
    # QANT-45 failed all three attempts, twice, on exactly that, and passed first try with
    # this one field flipped. It also explains why four workers looked *more* stable than one:
    # another worker's traffic is the event that drains the queue.
    docker exec "$PG" psql -U novatalks -d novatalks -v ON_ERROR_STOP=1 -c "
        update accounts set active_until = now() + interval '5 years',
                            locale = 'en',
                            limits = jsonb_set(jsonb_set(limits::jsonb, '{users}', '100'),
                                               '{enableAutomaticAgentAssignment}', 'true'),
                            updated_at = now()
        where id = 1" >/dev/null || fail "could not apply the stand settings" "$PG"
    # BotFlow presents this token on every call; with no agent_bots row carrying it the engine
    # answers 401 a minute forever.
    bot_hook="http://127.0.0.1:${BOTFLOW_PORT}/redbot/novatalks-botagent/1"
    # An update, not an insert: the seeds already made one token for this bot, and a second
    # row would leave the engine signing with one value while BotFlow expects the other —
    # which is what silently stopped every chatbot reply before AGENTBOT_INBOX_TOKEN was
    # passed above. Updating in place cannot produce that ambiguity even if the seeder
    # changes shape again. `returning 1` because an UPDATE that matches nothing says so only
    # in a row count, and that count used to go to /dev/null.
    inserted="$(docker exec "$PG" psql -U novatalks -d novatalks -v ON_ERROR_STOP=1 -qtAX -c "
        update agent_bots set outgoing_url = '${bot_hook}' where account_id = 1;
        update access_tokens set token = '${bot_token}', updated_at = now()
        where owner_type = 'AgentBot'
          and owner_id in (select id from agent_bots where account_id = 1)
        returning 1" 2>&1)" || fail "could not set the AgentBot token: ${inserted}" "$PG"
    [ "$inserted" = "1" ] \
        || fail "expected exactly one AgentBot token row for account 1, psql returned: ${inserted:-nothing}" "$PG"

    # The suite authenticates two ways, and neither works with the stand's credentials here:
    # it logs into the UI as the seeded admin, and it calls the Engine API with a static
    # api_access_token header (macros, skills and calendars helpers, and the prune). The seeds
    # create the admin but no token of its own, exactly as they create the AgentBot without
    # one — so generate a token per run and insert it against that user.
    admin_user="$(env_value DEFAULT_ADMIN_USER "${WORK}/engine.env")"
    admin_user="${admin_user:-support@novatalks.ai}"
    admin_pass="$(env_value DEFAULT_USER_PASSWORD "${WORK}/engine.env")"
    [ -n "$admin_pass" ] || fail "the chart rendered no DEFAULT_USER_PASSWORD — the suite could not log in"
    # The suite creates agents with this same password, and the engine's default policy wants
    # a length of 8 with an upper, a lower, a digit and a special. A password that seeds fine
    # and is refused at POST /agents reads as a product fault in a test, three steps from the
    # value that caused it — so check it here, where the value is.
    printf '%s' "$admin_pass" | grep -q '[A-Z]' \
        && printf '%s' "$admin_pass" | grep -q '[a-z]' \
        && printf '%s' "$admin_pass" | grep -q '[0-9]' \
        && printf '%s' "$admin_pass" | grep -q '[^A-Za-z0-9]' \
        && [ "${#admin_pass}" -ge 8 ] \
        || fail "DEFAULT_USER_PASSWORD does not satisfy the engine's default password policy (8+, upper, lower, digit, special) — every agent the suite creates will be refused with 422"
    api_token="$(openssl rand -hex 24)"
    # Masked before it reaches a psql command line or an environment file: the failure paths
    # around here print container logs, and nova.ci is public.
    printf '::add-mask::%s\n' "$api_token"
    inserted="$(docker exec "$PG" psql -U novatalks -d novatalks -v ON_ERROR_STOP=1 -qtAX -c "
        insert into access_tokens (owner_type, owner_id, token, created_at, updated_at)
        select 'User', id, '${api_token}', now(), now() from users where email = '${admin_user}'
        limit 1 returning 1" 2>&1)" || fail "could not seed the API token: ${inserted}" "$PG"
    [ "$inserted" = "1" ] \
        || fail "no users row for ${admin_user}, so every API call the suite makes answers 401 (psql said: ${inserted:-nothing})" "$PG"
    # The NovaTalks connector in BotFlow presents its own token on every call into the engine
    # — find_or_create, messages, everything the channel flows do. The seeds create no row for
    # it, and it only appeared to work while it held the same string as the agent bot's.
    inserted="$(docker exec "$PG" psql -U novatalks -d novatalks -v ON_ERROR_STOP=1 -qtAX -c "
        insert into access_tokens (owner_type, owner_id, token, created_at, updated_at)
        select 'User', id, '${engine_token}', now(), now() from users where email = '${admin_user}'
        limit 1 returning 1" 2>&1)" || fail "could not seed the BotFlow connector token: ${inserted}" "$PG"
    [ "$inserted" = "1" ] \
        || fail "no users row for ${admin_user}, so every call BotFlow makes into the engine answers 401" "$PG"

    log "seeded an API token for ${admin_user}, and BotFlow's own connector token"

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
    # ENGINE_URL and AGENT_BOT_TOKEN are the browser's path, and neither is in that arm because
    # a DAST scan never needs them. API_ACCESS_TOKENS only covers the token the engine holds
    # for its own calls; a request from a logged-in user arrives carrying *that user's* engine
    # token, which the dialer knows nothing about, so its auth middleware asks the engine to
    # vouch for it — `integrationService.fetchTokenInfo`, against ENGINE_URL with
    # AGENT_BOT_TOKEN as its own credential. With ENGINE_URL unset axios throws `Invalid URL`,
    # the middleware's catch-all turns that into a 400, and the engine proxies the 400 back:
    # the Dialer Settings page renders its header, no rows, and every @campaigns spec fails on
    # an input that never appeared. The engine's own 200 on the same path hides it — that call
    # presents an api_access_token and never takes this branch.
    docker run -d --name "$DIALER" --network host --env-file "${WORK}/dialer.env" \
        -e NODE_ENV=production -e APP_PORT="${DIALER_PORT}" \
        -e API_ACCESS_TOKENS="$dialer_token" \
        -e ENGINE_URL="http://127.0.0.1:${ENGINE_PORT}" \
        -e AGENT_BOT_TOKEN="$api_token" \
        -e DATABASE_HOST=127.0.0.1 -e DATABASE_PORT=5432 \
        -e DATABASE_USERNAME=novatalks -e DATABASE_PASSWORD=e2e-local -e DATABASE_NAME=dialer \
        -e DATABASE_URL="postgresql://novatalks:e2e-local@127.0.0.1:5432/dialer" \
        -e NATS_SERVERS=127.0.0.1:4222 \
        "$DIALER_IMAGE" >/dev/null || fail "the dialer container refused to start"
    started "$DIALER" "the dialer"
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
        -v "${WORK}/proxy.crt:/etc/e2e-proxy-ca.crt:ro" \
        -e NODE_EXTRA_CA_CERTS=/etc/e2e-proxy-ca.crt \
        -e BF_REDIS_HOST=127.0.0.1 -e BF_REDIS_PORT=6379 -e BF_REDIS_DB=15 \
        -e NOVATALKS_ENGINE_URL="http://127.0.0.1:${ENGINE_PORT}" \
        -e NOVATALKS_BOTAGENT_WEBHOOK="$bot_hook" \
        "$BOTFLOW_IMAGE" >/dev/null || fail "the botflow container refused to start"
    started "$BOTFLOW" "botflow"
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
        -e VITE_APP_WEBSOCKET_URL="https://localhost:${PROXY_PORT}" \
        "$UI_IMAGE" >/dev/null || fail "the ui container refused to start"
    started "$UI" "the ui"
    wait_http "ui" "http://127.0.0.1:${UI_PORT}/" "$UI"

    log "front proxy"
    # TLS, self-signed, valid for the life of the run. Not decoration: the web widget's
    # bundle is served from a CDN and builds its socket URL as wss:// + the page host, with
    # no setting anywhere to change it — /widget/settings returns no socket address at all.
    # Against a plain-http origin it retries the handshake forever and the widget sits on a
    # spinner with the conversation already created (probe run 35611733629, QANT-48).
    #
    # Terminating TLS here is also *less* divergence, not more: the chart renders https URLs
    # because Traefik terminates TLS in front of the lab, and this used to be rewritten away.
    # The certificate itself is generated up with the rest of the setup, because the engine and
    # botflow are started before this point and mount it to trust this proxy.
    # Nothing may already hold the port, and "something answers on it" is not the same thing
    # as "our proxy is up": probe 35582573611 read nginx's own log and found
    # `bind() to 0.0.0.0:8080 failed (98: Address in use)` — the stranger already there
    # answered 200 on / and 404 on every route, which is indistinguishable from a working
    # proxy from the outside, and had been passing this wait for three runs.
    # No separate port check here any more. One was written for the stranger that held 8080 on
    # the runner, first as an HTTP probe and then against `ss` — and neither is portable: ss
    # does not exist on a Mac, netstat takes different flags there, and with host networking
    # the ports live in Docker's Linux VM rather than on the machine asking. `started` below
    # catches the same failure in both places and reports it better, because it prints nginx's
    # own line naming the port it could not bind.
    # The lab's Traefik route table, copied rather than invented: a route the stand has and the
    # runner lacks is a test that passes in one place and fails in the other for no product
    # reason. /redbot must come before /, and the dialer prefix before the engine's /api/.
    cat > "${WORK}/proxy.conf" <<EOF
server {
    listen ${PROXY_PORT} ssl;
    ssl_certificate     /etc/nginx/tls/proxy.crt;
    ssl_certificate_key /etc/nginx/tls/proxy.key;
    client_max_body_size 64m;
    # The Engine's static API credential travels in a header called api_access_token, and
    # nginx drops headers containing underscores unless told otherwise. Traefik does not, so
    # the lab never saw this: every API call the suite made through this proxy arrived at the
    # engine with no token and was answered 401, while the same token sent straight at the
    # container answered 200.
    underscores_in_headers on;
    location /redbot { proxy_pass http://127.0.0.1:${BOTFLOW_PORT}; ${PROXY_HEADERS:-} }
    location /api/v1/dialer/ { proxy_pass http://127.0.0.1:${DIALER_PORT}; }
    location /api/ { proxy_pass http://127.0.0.1:${ENGINE_PORT}; }
    location /auth/ { proxy_pass http://127.0.0.1:${ENGINE_PORT}; }
    location /store/ { proxy_pass http://127.0.0.1:${ENGINE_PORT}; }
    location /widget { proxy_pass http://127.0.0.1:${ENGINE_PORT}; }
    location /api-docs { proxy_pass http://127.0.0.1:${ENGINE_PORT}; }
    location /webwidget-docs { proxy_pass http://127.0.0.1:${ENGINE_PORT}; }
    # proxy_read_timeout, because nginx's default is 60 s and neither end of this socket sends
    # a heartbeat: the UI's WebSocketConnector has no ping interval and the engine's
    # EventsGateway has no pong sweep, so a logged-in page that is merely watching sends
    # nothing for minutes at a time and nginx closes a perfectly healthy connection. The client
    # reconnects a second later, so it reads as "the socket keeps dropping" rather than as a
    # timeout. Traefik in front of the lab applies no such limit, which is why only this target
    # shows it — the same shape as underscores_in_headers above.
    location /ws { proxy_pass http://127.0.0.1:${ENGINE_PORT}; proxy_http_version 1.1;
                   proxy_read_timeout 3600s; proxy_send_timeout 3600s;
                   proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; }
    location /webrtc-ws { proxy_pass http://127.0.0.1:${ENGINE_PORT}; proxy_http_version 1.1;
                          proxy_read_timeout 3600s; proxy_send_timeout 3600s;
                          proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; }
    location / { proxy_pass http://127.0.0.1:${UI_PORT}; }
}
EOF
    docker run -d --name "$PROXY" --network host \
        -v "${WORK}/proxy.conf:/etc/nginx/conf.d/default.conf:ro" \
        -v "${WORK}/proxy.crt:/etc/nginx/tls/proxy.crt:ro" \
        -v "${WORK}/proxy.key:/etc/nginx/tls/proxy.key:ro" \
        nginx:1.27-alpine >/dev/null || fail "the proxy container refused to start"
    started "$PROXY" "the proxy"
    wait_http "proxy" "https://127.0.0.1:${PROXY_PORT}/" "$PROXY"
    # Answering is not routing. botflow is known to answer 200 on its own port by now, so the
    # same path through the proxy must too — that is the one check that distinguishes our
    # nginx, with the stand's route table, from anything else listening on this port.
    proxy_code="$(http_code "https://127.0.0.1:${PROXY_PORT}/redbot/")"
    if [ "$proxy_code" != "200" ]; then
        fail "the proxy answers ${proxy_code} on /redbot/ while botflow answers 200 on its own port — it is not routing" "$PROXY"
    fi

    # Hand the run the address to point the suite at, rather than have the workflow repeat the
    # port: it already lives here and in the chart values, and a third copy is the one that
    # would be missed. The Node-RED credentials go with it for the same reason — the suite
    # needs them and they are fixed fakes, not secrets.
    # Always to a file, and to GITHUB_ENV as well when there is one. Without the file a local
    # run has no way to learn the origin or the stack's own credentials, which is most of what
    # somebody needs in order to point the suite at it.
    {
        printf 'ENV_URL=https://localhost:%s\n' "$PROXY_PORT"
        printf 'BOTFLOW_URL=https://localhost:%s/redbot\n' "$PROXY_PORT"
        printf 'BOTFLOW_ADMIN_LOGIN=%s\n' "$STACK_BF_LOGIN"
        printf 'BOTFLOW_ADMIN_PASSWORD=%s\n' "$STACK_BF_PASSWORD"
        printf 'UI_ADMIN_LOGIN=%s\n' "$admin_user"
        printf 'UI_ADMIN_PASSWORD=%s\n' "$admin_pass"
        printf 'API_TOKEN=%s\n' "$api_token"
        printf 'NODE_EXTRA_CA_CERTS=%s\n' "${WORK}/proxy.crt"
    } > "${WORK}/stack.env"
    chmod 600 "${WORK}/stack.env"

    if [ -n "${GITHUB_ENV:-}" ]; then
        {
            printf 'E2E_STACK_ORIGIN=https://localhost:%s\n' "$PROXY_PORT"
            # Node trusts it through this; Chromium does not read it, and is told to ignore
            # certificate errors in playwright.config.ts instead.
            printf 'NODE_EXTRA_CA_CERTS=%s\n' "${WORK}/proxy.crt"
            printf 'E2E_STACK_BOTFLOW_LOGIN=%s\n' "$STACK_BF_LOGIN"
            printf 'E2E_STACK_BOTFLOW_PASSWORD=%s\n' "$STACK_BF_PASSWORD"
            printf 'E2E_STACK_UI_LOGIN=%s\n' "$admin_user"
            printf 'E2E_STACK_UI_PASSWORD=%s\n' "$admin_pass"
            printf 'E2E_STACK_API_TOKEN=%s\n' "$api_token"
        } >> "$GITHUB_ENV"
    fi
    # The API token, checked on the path the suite actually uses. Sending it straight at the
    # container proved only that the token is good: the first version of this check did that,
    # passed, and the suite still got 401 on every call — because nginx drops underscored
    # headers and api_access_token never reached the engine. A check that avoids the proxy
    # cannot see the proxy's own faults.
    token_code="$(docker exec "$PROBE" curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
        -H "api_access_token: ${api_token}" \
        "https://127.0.0.1:${PROXY_PORT}/api/v1/accounts/1/wrupup-codes" 2>/dev/null || true)"
    [ "$token_code" = "200" ] \
        || fail "the API token answers ${token_code} through the proxy — the suite authenticates every call this way" "$PROXY"
    log "the API token authenticates through the proxy (HTTP ${token_code})"

    log "stack is up on https://localhost:${PROXY_PORT}"
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
