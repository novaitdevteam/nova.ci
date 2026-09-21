#!/usr/bin/env bash
# Bring the ephemeral stack up on a developer's machine, with the same stack.sh CI runs.
#
#   ./local.sh up      # start it; prints the origin to point the suite at
#   ./local.sh down    # stop it, with each container's log if it went wrong
#   ./local.sh env     # print the variables to export before running the suite
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

    # s3 with values that resolve to nothing, never `local`: there is no local driver, and
    # asking for one kills the engine in provider init. Attachments fail; nothing else does.
    export FILE_DRIVER=s3
    export AWS_S3_ENDPOINT="${AWS_S3_ENDPOINT:-http://s3.example.invalid}"
    export AWS_S3_BUCKET="${AWS_S3_BUCKET:-e2e-dummy-not-a-real-bucket}"
    export AWS_S3_ACCESS_KEY="${AWS_S3_ACCESS_KEY:-e2e-dummy-not-a-real-key}"
    export AWS_S3_SECRET="${AWS_S3_SECRET:-e2e-dummy-not-a-real-secret}"
}

case "${1:-up}" in
    up)
        load_env
        # Idempotent: helm keeps the login, so this is a no-op on every run after the first.
        printf '%s' "${pat_ket:?pat_ket is not in nova.ci/.env}" \
            | helm registry login ghcr.io -u "${GHCR_USER:-$(git -C "$CI_REPO" config user.name)}" --password-stdin >/dev/null
        "${STACK_DIR}/stack.sh" up
        echo
        echo "Point the suite at it:"
        "$0" env
        ;;
    down)
        "${STACK_DIR}/stack.sh" down
        ;;
    env)
        load_env
        port="${E2E_PROXY_PORT:-18080}"
        work="${RUNNER_TEMP:-/tmp}/e2e-stack"
        cat <<EOF
  export ENV_URL=https://localhost:${port}
  export BOTFLOW_URL=https://localhost:${port}/redbot
  export NODE_EXTRA_CA_CERTS=${work}/proxy.crt
  export RESET_STAND=off WORKERS=1
  # the rest — the stack's own admin and tokens — are in ${work}/*.env
EOF
        ;;
    *)
        echo "usage: local.sh up|down|env" >&2
        exit 2
        ;;
esac
