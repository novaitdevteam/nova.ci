#!/usr/bin/env bash
#
# The one per-repository DAST table.
#
# Sourced by every consumer, because there are now three and copies drift:
#   ci-build-ntk-on-push-tags-build.yaml  "Resolve DAST target"      (browser)
#   ci-build-ntk-on-push-tags-build.yaml  "Resolve api-scan target"  (api)
#   ci-dast-pentest.yaml                  (either)
#
# Every value here is read from the repository it describes — its Dockerfile, its guard,
# its schema, its Helm chart — never inferred from a sibling. A guessed port does not
# crash: it scans nothing and reports it clean.
#
# dast_resolve_target <repo> <surface:api|browser>
#   Sets DT_* in the caller's scope. Returns 1 on an unknown repository/surface pair,
#   after an ::error:: — the default arm never guesses.

dast_resolve_target() {
    local repo="$1" surface="$2"

    DT_PORT=""; DT_HEALTH_PATH=""; DT_SPEC_PATH=""
    DT_NEEDS_DB=false; DT_NEEDS_NATS=false
    DT_AUTH_MODE=""; DT_LOGIN_PATH=""; DT_AUTH_HEADER=""; DT_AUTH_SCHEME_PREFIX=""
    DT_TOKEN_SQL=""; DT_TOKEN_INSERT_SQL=""; DT_TOKEN_ENV_VAR=""
    DT_SETUP_COMMAND=""; DT_SWAGGER_ENABLE=false; DT_EXTRA_ENV=""; DT_ZAP_CONTEXT=""

    case "${repo}/${surface}" in
        novatalks.ui/browser)
            # nginx serving the static Vue app. Port and health path from the production
            # Helm chart (novatalks.charts, novatalks_v5/values.yaml) — authoritative
            # because it is what runs in prod.
            DT_PORT=8000; DT_HEALTH_PATH=/livez
            ;;
        novatalks.core/browser)
            # NestJS engine. Same chart source as above.
            DT_PORT=3000; DT_HEALTH_PATH=/livez; DT_NEEDS_DB=true
            ;;
        nova.botflow/browser)
            # No dedicated HTTP health route — the chart probes over tcpSocket. "/" is
            # correct: the boot wait-loop accepts any HTTP response, 404 included, because
            # it tests whether the process is listening, not whether a route exists.
            # Do not "fix" this to /livez.
            DT_PORT=1880; DT_HEALTH_PATH=/; DT_NEEDS_DB=true
            ;;
        novatalks.core/api)
            DT_PORT=3000; DT_HEALTH_PATH=/livez; DT_SPEC_PATH=/api-docs-json
            DT_NEEDS_DB=true
            DT_AUTH_MODE=login; DT_LOGIN_PATH=/auth/sign_in
            DT_AUTH_HEADER=Authorization; DT_AUTH_SCHEME_PREFIX='Bearer '
            DT_SWAGGER_ENABLE=true
            # No setup command: docker/engine.Dockerfile's runtime stage installs
            # nodejs-24 and not npm, and its entrypoint.sh already runs create-database,
            # sequelize db:migrate and seed-database with plain `node` before the app
            # serves anything.
            DT_SETUP_COMMAND=''
            ;;
        nova.chatsconnector.telegram-client-api/api)
            # api_access_token header (setup-swagger.ts), DB-backed token in
            # tokens.api_token joined to token_roles.role (schema.prisma), seeded by
            # the image's own entrypoint, Swagger served unconditionally, no health route.
            DT_PORT=3000; DT_HEALTH_PATH=/; DT_SPEC_PATH=/api-docs-json
            DT_NEEDS_DB=true
            DT_AUTH_MODE=db-token
            DT_AUTH_HEADER=api_access_token; DT_AUTH_SCHEME_PREFIX=''
            DT_TOKEN_SQL="SELECT t.api_token FROM tokens t JOIN token_roles r ON t.role_id = r.id WHERE r.role = 'SUPER_ADMIN' ORDER BY t.id LIMIT 1;"
            DT_SETUP_COMMAND=''
            DT_SWAGGER_ENABLE=false
            # Boot dummies the connector's config validator rejects a blank for.
            DT_EXTRA_ENV='TELEGRAM_API_ID=12345
TELEGRAM_API_HASH=00000000000000000000000000000000
NOVATALKS_ACCESS_TOKEN=dast-dummy-dummy-token
ENCRYPTION_SECRET=dast-dummy-dummy-dummy-dummy-dummy'
            ;;
        # Only the three browser-surface repositories reach dast-scan (see the job
        # gate in ci-build-ntk-on-push-tags-build.yaml). The ZAP baseline is a browser
        # tool — on a headless JSON API it finds three response headers and nothing a
        # browser would; the connectors (telegram/whatsapp/signal/dialer) and
        # geoip/uspacy were removed on 2026-09-01. Their real coverage is the
        # authenticated api-scan (see the api-scan job), a tracked per-repo expansion;
        # a generalised api-scan will need their ports/health paths, recorded in the
        # tracking note, not here.
        *)
            echo "::error::No DAST configuration for '${repo}' on the '${surface}' surface. Add an arm with its port, health path and auth read from that repository's own code — a guessed value scans nothing and reports it clean."
            return 1
            ;;
    esac
}
