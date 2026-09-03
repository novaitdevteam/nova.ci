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
            # correct here: the boot wait-loop accepts any HTTP response, 404 included,
            # because it is only testing whether the process is listening, not whether
            # a route exists. Do not "fix" this to /livez.
            DT_PORT=1880; DT_HEALTH_PATH=/
            # Needs redis or postgres depending on its storage configuration; bringing
            # up both is simpler than modelling the choice, and an unused container
            # costs a few seconds.
            DT_NEEDS_DB=true
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
            # serves anything. `npm run db:setup:prod` here could only ever answer
            # `sh: npm: not found` — and did, on run 33752263531.
            DT_SETUP_COMMAND=''
            ;;
        nova.chatsconnector.telegram-client-api/api)
            # Verified in the connector's code: api_access_token header (setup-swagger.ts),
            # DB-backed token in tokens.api_token joined to token_roles.role (schema.prisma),
            # seeded by `npm run db:seed`, Swagger served unconditionally, no health route so "/".
            DT_PORT=3000; DT_HEALTH_PATH=/; DT_SPEC_PATH=/api-docs-json
            DT_NEEDS_DB=true
            DT_AUTH_MODE=db-token
            DT_AUTH_HEADER=api_access_token; DT_AUTH_SCHEME_PREFIX=''
            DT_TOKEN_SQL="SELECT t.api_token FROM tokens t JOIN token_roles r ON t.role_id = r.id WHERE r.role = 'SUPER_ADMIN' ORDER BY t.id LIMIT 1;"
            # No setup_command either: this image's entrypoint.sh runs `npm run
            # db:setup` itself before starting the app, so the exec was racing it and
            # both failed the same way — Prisma P1012, DATABASE_URL not found. scan.sh
            # now sets DATABASE_URL for the container, which fixes the entrypoint's own
            # run; a second one over `docker exec` buys nothing.
            DT_SETUP_COMMAND=''
            DT_SWAGGER_ENABLE=false
            # Boot dummies the connector's config validator rejects a blank for — the same
            # values the removed baseline arm used; DATABASE_URL for Prisma is built by scan.sh.
            DT_EXTRA_ENV='TELEGRAM_API_ID=12345
TELEGRAM_API_HASH=00000000000000000000000000000000
NOVATALKS_ACCESS_TOKEN=dast-dummy-dummy-token
ENCRYPTION_SECRET=dast-dummy-dummy-dummy-dummy-dummy'
            ;;
        nova.chatsconnector.whatsapp-client-api/api)
            # Verified in the connector's own code, not copied from telegram: the
            # api_access_token header (roles.guard.ts); tokens/token_roles schema
            # (token.model.ts, token-role.model.ts — tableName 'tokens'/'token_roles',
            # schema 'public', role_id FK not null); the role value is 'super_admin'
            # (token-role.enum.ts) — lowercase, unlike telegram's 'SUPER_ADMIN'. Swagger
            # is served unconditionally (setup-swagger.ts calls SwaggerModule.setup
            # with no env gate), spec JSON at /api-docs-json. Health at GET /health
            # (health.controller.ts, @Public(), pings the db and its own /api-docs).
            DT_PORT=3000; DT_HEALTH_PATH=/health; DT_SPEC_PATH=/api-docs-json
            DT_NEEDS_DB=true
            DT_AUTH_MODE=db-insert
            DT_AUTH_HEADER=api_access_token; DT_AUTH_SCHEME_PREFIX=''
            DT_TOKEN_INSERT_SQL="INSERT INTO tokens (api_token, role_id, created_at, updated_at) VALUES ('%TOKEN%', (SELECT id FROM token_roles WHERE role = 'super_admin' LIMIT 1), NOW(), NOW());"
            # docker/server.Dockerfile's runtime stage ships no npm, but entrypoint.sh
            # still migrates and seeds itself, straight through `node` against the
            # compiled dist/scripts/*.js (nest build compiles scripts/ and the seeders
            # too, and their runtime deps — sequelize, sequelize-cli, dotenv,
            # reflect-metadata — all survive `npm prune --omit=dev` because they are
            # listed under "dependencies", not "devDependencies"). No setup command
            # needed either way.
            DT_SETUP_COMMAND=''
            DT_SWAGGER_ENABLE=false
            # No boot-time config validator here at all — every src/config/*.ts factory
            # reads process.env directly with no Joi/class-validator schema, so nothing
            # rejects a blank var at startup (unlike signal, below).
            DT_EXTRA_ENV=''
            ;;
        nova.chatsconnector.signal-client-api/api)
            # Expected to match whatsapp; verified independently against this
            # connector's own roles.guard.ts and token.model.ts/token_role.model.ts, not
            # copied — and it does match: same header, same tableName/schema/columns,
            # same 'super_admin' role value in token-role.enum.ts, same Dockerfile
            # shape (no npm at runtime, entrypoint.sh self-migrates and self-seeds).
            #
            # Two things do NOT match whatsapp, found by reading this repository's own
            # files rather than assuming symmetry:
            #   - no health controller at all (grepped every @Controller() in src/ —
            #     none named 'health', no HealthModule), so DT_HEALTH_PATH is "/" like
            #     telegram/botflow: any HTTP response, 404 included, only proves the
            #     process is listening.
            #   - env.validation.ts adds a Joi schema (loaded via envValidationSchema in
            #     app.module.ts) requiring STORAGE_PATH/S3_ENDPOINT/S3_ACCESS_KEY_ID/
            #     S3_SECRET_ACCESS_KEY/S3_BUCKET non-blank; whatsapp has no equivalent
            #     validator. Dockerfile deliberately leaves STORAGE_PATH unset in prod
            #     (the signal-cli bridge chowns that mount), so these five are boot
            #     dummies here, not defaults recovered from .env.example.
            DT_PORT=3000; DT_HEALTH_PATH=/; DT_SPEC_PATH=/api-docs-json
            DT_NEEDS_DB=true
            DT_AUTH_MODE=db-insert
            DT_AUTH_HEADER=api_access_token; DT_AUTH_SCHEME_PREFIX=''
            DT_TOKEN_INSERT_SQL="INSERT INTO tokens (api_token, role_id, created_at, updated_at) VALUES ('%TOKEN%', (SELECT id FROM token_roles WHERE role = 'super_admin' LIMIT 1), NOW(), NOW());"
            DT_SETUP_COMMAND=''
            DT_SWAGGER_ENABLE=false
            DT_EXTRA_ENV='STORAGE_PATH=/tmp/dast-storage
S3_ENDPOINT=https://dast-dummy.example.invalid
S3_ACCESS_KEY_ID=dast-dummy
S3_SECRET_ACCESS_KEY=dast-dummy
S3_BUCKET=dast-dummy'
            ;;
        novatalks.dialer/api)
            # env-token, confirmed in auth.middleware.ts: a request carrying
            # api_access_token that matches an entry in app.apiAccessTokens
            # (API_ACCESS_TOKENS, comma-split in app.config.ts) short-circuits before
            # any DB lookup or outbound call to the engine.
            #
            # Health from health.controller.ts's /readyz, which checks Prisma and Redis —
            # /livez here only checks memory thresholds and reports healthy even before
            # the database connects, so it is the wrong probe for this repository
            # specifically. Both are excluded from the global "api/v1/dialer" prefix by
            # global-prefix.ts, so they stay unprefixed. Port is 3000: app.config.ts's
            # Joi default is 3006 (matched by .env.example, a local-dev file not shipped
            # in the image) and docker/server.Dockerfile's EXPOSE says 3000, but neither
            # is what's deployed — docs/sast-dast.md's already-verified note on the
            # removed baseline arm cites the production chart (novatalks.charts,
            # novatalks_v5/values.yaml, dialer.containerPort: 3000, probing /livez and
            # /readyz) as authoritative, and this repository's own convention elsewhere
            # (novatalks.ui/core) is chart over code default when they disagree.
            # Functionally moot either way — scan.sh forces APP_PORT to whatever DT_PORT
            # says — but 3000 matches what's actually deployed.
            #
            # Swagger is served unconditionally (setup-swagger.ts, no env gate) but
            # mounted under the API prefix, not the default path: spec JSON is at
            # /api/v1/dialer/api-docs-json.
            DT_PORT=3000; DT_HEALTH_PATH=/readyz; DT_SPEC_PATH=/api/v1/dialer/api-docs-json
            DT_NEEDS_DB=true
            # nats.config.ts's registerAs factory (loaded in app.module.ts) calls
            # NATS_SUBJECTS.split(',') unconditionally at config-load time, so a missing
            # NATS_SUBJECTS throws before the app ever reaches app.listen() — needed
            # regardless of whether a NATS broker is reachable. main.ts also awaits
            # `microService.listen()` (a real NATS connection) before app.listen(), so
            # DT_NEEDS_NATS is set honestly here even though, as of this writing,
            # dast-api/scan.sh has no NATS bring-up block (only dast/scan.sh, the
            # browser-surface baseline, does) — until that gap is closed this arm's
            # api-scan is expected to loud-skip on the NATS connection, not silently
            # scan the wrong thing.
            DT_NEEDS_NATS=true
            DT_AUTH_MODE=env-token
            DT_AUTH_HEADER=api_access_token; DT_AUTH_SCHEME_PREFIX=''
            DT_TOKEN_ENV_VAR=API_ACCESS_TOKENS
            # entrypoint.sh runs `npm run db:setup` itself (npm survives here — this
            # Dockerfile never prunes devDependencies) before exec, so no setup command
            # is needed.
            DT_SETUP_COMMAND=''
            DT_SWAGGER_ENABLE=false
            DT_EXTRA_ENV='NATS_SUBJECTS=campaign.*'
            ;;
        # Only the three browser-surface repositories reach dast-scan (see the job
        # gate in ci-build-ntk-on-push-tags-build.yaml). The ZAP baseline is a browser
        # tool — on a headless JSON API it finds three response headers and nothing a
        # browser would; the connectors (telegram/whatsapp/signal/dialer) and
        # geoip/uspacy were removed on 2026-09-01. Their real coverage is the
        # authenticated api-scan (see the api-scan job): whatsapp, signal and dialer
        # now have arms above. novatalks.geoip-api does not — it ships no OpenAPI/
        # Swagger spec at all (a ~220-line single-file Fastify service, no
        # @fastify/swagger dependency in package.json), and api-scan is spec-driven
        # only, with no spider fallback, so there is nothing for it to discover routes
        # from. Adding an arm would only ever produce a guaranteed, permanent loud
        # skip. It has no authentication either (grepped the whole file — no guard, no
        # middleware, no header check), which would be DT_AUTH_MODE=none if a spec ever
        # gets added.
        *)
            echo "::error::No DAST configuration for '${repo}' on the '${surface}' surface. Add an arm with its port, health path and auth read from that repository's own code — a guessed value scans nothing and reports it clean."
            return 1
            ;;
    esac
}
