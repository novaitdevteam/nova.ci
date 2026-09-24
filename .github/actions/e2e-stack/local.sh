#!/usr/bin/env bash
# Bring the ephemeral stack up on a developer's machine, with the same stack.sh CI runs.
#
#   ./local.sh up      # start it; prints the origin to point the suite at
#   ./local.sh down    # stop it, with each container's log if it went wrong
#   ./local.sh env     # print the variables to export before running the suite
#   ./local.sh test [@tag] [playwright args]  # run the suite in a container on the same network
#
# WHY THIS EXISTS. On 2026-09-21 a day of CI cycles was spent on things a laptop finds in
# seconds: `sed -i -E` is GNU-only, a container that died on a taken port went unnoticed
# because `docker run -d` had already succeeded, and both workflows carried a
# FILE_DRIVER=local fallback for a driver that does not exist in either the engine or the
# dialer. The first two lived in the branch all day and passed through fifteen green-looking
# runs; the third had never been taken because the secrets were always present. A CI round
# trip is minutes plus a runner queue and gives you one log; this gives you the containers.
#
# CREDENTIALS come from the repositories' own .env files and are never printed:
#   nova.ci/.env               pat_ket                — reads the chart package from GHCR
#   novatalks.tests/.env       BOTFLOW_ADMIN_*        — the stand whose flows are copied
# Neither is passed on a command line, so neither reaches a process list.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_REPO="$(cd "${STACK_DIR}/../../.." && pwd)"
TESTS_REPO="${E2E_TESTS_REPO:-${CI_REPO%/*}/novatalks.tests}"

load_env() {
    [ -f "${CI_REPO}/.env" ] || { echo "no ${CI_REPO}/.env — it holds the GHCR token" >&2; exit 1; }
    [ -f "${TESTS_REPO}/.env" ] || { echo "no ${TESTS_REPO}/.env — it holds the stand's BotFlow admin" >&2; exit 1; }
    set -a
    # shellcheck source=/dev/null
    . "${CI_REPO}/.env"
    # shellcheck source=/dev/null
    . "${TESTS_REPO}/.env"
    set +a

    export CHART_VERSION="${CHART_VERSION:-5.4.7}"
    export ENGINE_IMAGE="${ENGINE_IMAGE:-ghcr.io/novaitdevteam/novatalks.core:2026_R3_NC2-2778_engine_f64f9736}"
    export UI_IMAGE="${UI_IMAGE:-ghcr.io/novaitdevteam/novatalks.ui:2026_R3_development_20fdf74f}"
    export BOTFLOW_IMAGE="${BOTFLOW_IMAGE:-ghcr.io/novaitdevteam/nova.botflow:2026_R3_master_f9126a11}"
    export DIALER_IMAGE="${DIALER_IMAGE:-ghcr.io/novaitdevteam/novatalks.dialer:2026_R3_master_a81e7763}"

    export E2E_SOURCE_BOTFLOW_URL="${E2E_SOURCE_BOTFLOW_URL:-https://novatalks-e2e-tests.k3s.dev.novait.com.ua/redbot}"
    export E2E_SOURCE_BOTFLOW_LOGIN="${BOTFLOW_ADMIN_LOGIN:?BOTFLOW_ADMIN_LOGIN is not in the tests .env}"
    export E2E_SOURCE_BOTFLOW_PASSWORD="${BOTFLOW_ADMIN_PASSWORD:?BOTFLOW_ADMIN_PASSWORD is not in the tests .env}"

    # s3, never `local`: there is no local driver, and asking for one kills the engine in
    # provider init. It used to point at s3.example.invalid, which boots fine and fails every
    # upload — QANT-105 attaches two files to a menu item, Create answered with the engine's
    # `getaddrinfo ENOTFOUND s3.example.invalid`, the dialog stayed open over the page, and the
    # next click waited 30 s behind it. CI's ephemeral target has real R2 (the E2E_R2_*
    # secrets) and never saw it; only this machine did. So a local MinIO stands in, unless a
    # real endpoint is given. Credentials are obviously fake and exist only in that container.
    export FILE_DRIVER=s3
    if [ -z "${AWS_S3_ENDPOINT:-}" ]; then
        export AWS_S3_ENDPOINT=http://127.0.0.1:19000 AWS_S3_BUCKET=e2e-local AWS_S3_REGION=us-east-1
        export AWS_S3_ACCESS_KEY=e2e-local-minio AWS_S3_SECRET=e2e-local-not-a-real-secret
        USE_MINIO=yes
    fi
}

# 19000, not 9000, for the same reason the proxy is on 18080: ports near the defaults are the
# ones something else on a machine already holds. Pinned by digest — MinIO's release tags do
# not pull from Docker Hub, and `latest` would change under a run nobody changed.
MINIO_IMAGE="minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e"

start_minio() {
    docker rm -f e2e-minio >/dev/null 2>&1 || true
    docker run -d --name e2e-minio --network host \
        -e MINIO_ROOT_USER="$AWS_S3_ACCESS_KEY" -e MINIO_ROOT_PASSWORD="$AWS_S3_SECRET" \
        "$MINIO_IMAGE" server /data --address :19000 --console-address :19001 >/dev/null
    # The image carries mc, so the bucket is made from inside it: no second image, no host port.
    for _ in $(seq 1 30); do
        docker exec e2e-minio mc alias set local http://127.0.0.1:19000 "$AWS_S3_ACCESS_KEY" "$AWS_S3_SECRET" >/dev/null 2>&1 && break
        sleep 1
    done
    docker exec e2e-minio mc mb --ignore-existing "local/${AWS_S3_BUCKET}" >/dev/null \
        || { echo "MinIO did not come up, so uploads would fail exactly as before" >&2; docker logs e2e-minio >&2; exit 1; }
    echo "[local] MinIO on :19000, bucket ${AWS_S3_BUCKET}"
}

case "${1:-up}" in
    up)
        load_env
        # Idempotent: helm keeps the login, so this is a no-op on every run after the first.
        printf '%s' "${pat_ket:?pat_ket is not in nova.ci/.env}" \
            | helm registry login ghcr.io -u "${GHCR_USER:-$(git -C "$CI_REPO" config user.name)}" --password-stdin >/dev/null
        [ "${USE_MINIO:-}" = yes ] && start_minio
        "${STACK_DIR}/stack.sh" up
        echo
        echo "Point the suite at it:"
        "$0" env
        ;;
    down)
        "${STACK_DIR}/stack.sh" down
        docker rm -f e2e-minio >/dev/null 2>&1 || true
        ;;
    env)
        work="${RUNNER_TEMP:-/tmp}/e2e-stack"
        [ -f "${work}/stack.env" ] || { echo "no ${work}/stack.env — bring the stack up first" >&2; exit 1; }
        sed 's/^/  export /' "${work}/stack.env"
        echo "  export RESET_STAND=off WORKERS=1"
        ;;

    test)
        # The suite runs in a container on the stack's own network, for the same reason the
        # probes do: the host cannot reach a --network host container on a Mac. It also keeps
        # the run identical to CI — same image family, same addressing — so a pass here means
        # something about a pass there.
        # No mail credentials: the stack runs its own mail server and stack.env names it, so
        # the email specs read and write there instead of a real mailbox.
        # WORKERS is read before load_env, because the tests repository's .env sets it too and
        # would win: every "WORKERS=4 local.sh test" ran on one worker until this.
        workers="${WORKERS:-1}"
        load_env
        work="${RUNNER_TEMP:-/tmp}/e2e-stack"
        [ -f "${work}/stack.env" ] || { echo "no ${work}/stack.env — bring the stack up first" >&2; exit 1; }
        shift
        grep_arg="${1:-@CI}"
        shift || true   # anything after the tag goes to playwright as is: --retries 0 --trace on
        docker run --rm --network host \
            -v "${TESTS_REPO}:/work" -v "${work}:${work}:ro" -w /work \
            --env-file "${work}/stack.env" \
            -e RESET_STAND=off -e WORKERS="$workers" -e CI=true \
            -e SUITE_TIMEOUT_MINUTES="${SUITE_TIMEOUT_MINUTES:-110}" \
            -e TELEGRAM_URL=/telegram/ -e VIBER_URL=/viber/ -e META_URL=/messenger/channel-messenger/ \
            mcr.microsoft.com/playwright:v1.56.1-noble \
            npx playwright test --grep "$grep_arg" "$@"
        ;;
    *)
        echo "usage: local.sh up|down|env|test [@tag]" >&2
        exit 2
        ;;
esac
