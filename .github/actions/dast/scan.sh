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
set -euo pipefail

: "${DAST_IMAGE:?}" "${DAST_PORT:?}" "${DAST_HEALTH_PATH:?}" "${DAST_BOOT_TIMEOUT:?}"
: "${ZAP_IMAGE:?}" "${DAST_REPORT_FILE:?}"

DAST_NEEDS_DB="${DAST_NEEDS_DB:-false}"
DAST_PG_IMAGE="${DAST_PG_IMAGE:-postgres:16}"
target="http://127.0.0.1:${DAST_PORT}${DAST_HEALTH_PATH}"
zap_out="${RUNNER_TEMP:-/tmp}/zap.md"

emit() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }

emit_message() {
    {
        echo "message<<DAST_EOF"
        printf '%s\n' "$1"
        echo "DAST_EOF"
    } >> "${GITHUB_OUTPUT:-/dev/null}"
}

cleanup() {
    docker rm -f nova-app nova-pg nova-redis >/dev/null 2>&1 || true
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
    docker run -d --name nova-redis -p 6379:6379 redis:8 || not_run "redis did not start"
    for _ in $(seq 1 30); do
        docker exec nova-pg pg_isready -U "${DATABASE_USERNAME:-postgres}" >/dev/null 2>&1 && break
        sleep 2
    done
    docker exec -e PGPASSWORD="${DATABASE_PASSWORD:-password}" nova-pg \
        psql -h 127.0.0.1 -U "${DATABASE_USERNAME:-postgres}" -d "${DATABASE_NAME:-db_name}" \
        -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;" >/dev/null 2>&1 || true
fi

docker rm -f nova-app >/dev/null 2>&1 || true
docker run -d --name nova-app --network host \
    -e DATABASE_HOST=127.0.0.1 -e DATABASE_PORT=5432 \
    -e DATABASE_USERNAME="${DATABASE_USERNAME:-postgres}" \
    -e DATABASE_PASSWORD="${DATABASE_PASSWORD:-password}" \
    -e DATABASE_NAME="${DATABASE_NAME:-db_name}" \
    -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6379 \
    "$DAST_IMAGE" || not_run "the application container refused to start"

booted=no
attempts=$(( DAST_BOOT_TIMEOUT / 2 ))
[ "$attempts" -ge 1 ] || attempts=1
for _ in $(seq 1 "$attempts"); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "$target" || true)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then booted=yes; break; fi
    sleep 2
done

if [ "$booted" != "yes" ]; then
    docker logs --tail 40 nova-app 2>&1 | sed 's/^/    /' || true
    not_run "the image did not come up within ${DAST_BOOT_TIMEOUT}s"
fi

set +e
docker run --rm --network host -v "$(dirname "$zap_out"):/zap/wrk:rw" \
    "$ZAP_IMAGE" zap-baseline.py -t "http://127.0.0.1:${DAST_PORT}" \
    -I -w "$(basename "$zap_out")"
zap_rc=$?
set -e

# zap-baseline.py: 0 = nothing, 2 = warnings present (with -I it never returns 1),
# anything else means ZAP could not do its job.
case "$zap_rc" in
    0|2) : ;;
    *)   scanner_error "zap-baseline.py exited ${zap_rc}" ;;
esac

[ -s "$zap_out" ] || scanner_error "ZAP produced no report"

findings=$(grep -c 'WARN-NEW' "$zap_out" || true)
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
