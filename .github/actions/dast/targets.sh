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
    DT_UNSEEDED_ENV=""

    case "${repo}/${surface}" in
        novatalks.ui/browser)
            # nginx serving the static Vue app. Port and health path from the production
            # Helm chart (novatalks.charts, novatalks_v5/values.yaml) — authoritative
            # because it is what runs in prod.
            DT_PORT=8000; DT_HEALTH_PATH=/livez
            # DT_ZAP_CONTEXT deliberately stays empty. A context (contexts/novatalks-ui.context)
            # exists with the verified login request shape (/auth/sign_in, JSON body,
            # username/password/station), but this arm boots no backend
            # (DT_NEEDS_DB is false) and there is none to add one for: novatalks.ui is a
            # static nginx image with no API base URL configured anywhere (grepped
            # configurationParams.js, axios.client.js, entrypoint.sh's VITE_APP_* list) —
            # in production it shares an origin with novatalks.core through an ingress
            # this container never sees. Confirmed live on ghcr.io/novaitdevteam/
            # novatalks.ui:latest (2026-09-04): POST /auth/sign_in returns 405, and every
            # route returns the byte-identical static index.html shell (same ETag)
            # whether or not any credential is sent — nginx's try_files serves that shell
            # for everything, and Vue Router renders the difference client-side, where no
            # HTTP response ZAP can regex-match ever reflects it. Setting the context here
            # would pass -n/-U into a login that structurally cannot succeed, which is the
            # same "authenticated-looking, completely blind" failure this project already
            # hardened against in dast-api's -z replacer. Revisit once this arm boots (or
            # is proxied to) a real backend — see the context file's own header comment.
            ;;
        novatalks.core/browser)
            # NestJS engine. Same chart source as above.
            DT_PORT=3000; DT_HEALTH_PATH=/livez; DT_NEEDS_DB=true
            # DT_UNSEEDED_ENV: a fallback for the one caller that cannot seed this
            # repository's own .env.example at all — ci-dast-pentest.yaml runs in
            # nova.ci, not in a novatalks.core checkout. dast/scan.sh's own
            # scanned_repo/workspace_repo check detects exactly that mismatch and
            # applies this ONLY then; on the build workflow's own path (a real
            # novatalks.core checkout) it is never applied, so the real .env.example —
            # including its real S3 config — keeps deciding, unchanged. Overriding that
            # unconditionally would contradict CLAUDE.md's novatalks.core-scoped R2/S3
            # exception, and would have changed the trunk baseline scan that already
            # works (run reports WARN-NEW: 2, PASS: 65). Confirmed live on pentest run
            # 33882314584: the browser scan loud-skipped with "the image did not come up
            # within 180s", because GITHUB_WORKSPACE held nova.ci, not novatalks.core, so
            # nothing was seeded.
            #
            # The api arm below boots the identical image and needed exactly two things
            # to get past boot, for reasons that are not endpoint-specific: the
            # entrypoint's own seeder (create-database / migrate / seed-database) runs
            # before either surface serves anything, so a browser scan hits the same
            # seeder the api scan does and needs its own DEFAULT_ADMIN_USER/
            # DEFAULT_USER_PASSWORD (dast-api/scan.sh generates and masks these
            # unconditionally every run; dast/scan.sh has no equivalent, since its usual
            # path — a real .env.example — already supplies both); and
            # MulterConfigService.createMulterOptions() getOrThrow()s the five
            # AWS_S3_* keys at module registration, which happens regardless of which
            # surface is ever scanned afterward. DEFAULT_ADMIN_USER is a distinct
            # address from the api arm's own nova-ci-apiscan@example.invalid (same RFC
            # 2606 example.invalid domain, same reasoning) so the two arms' seeded rows
            # never collide if a future scan run ever pointed both at the same database.
            # Nothing here is read back — the browser scan never authenticates — so the
            # password only has to satisfy whatever strength check the seeder itself
            # applies; it is fixed rather than generated because targets.sh is a static
            # table, not a script that can call openssl per run.
            DT_UNSEEDED_ENV='DEFAULT_ADMIN_USER=nova-ci-dast@example.invalid
DEFAULT_USER_PASSWORD=Dast-Fallback-Passw0rd!
AWS_S3_ACCESS_KEY_ID=dast-dummy-not-a-real-key
AWS_S3_SECRET_ACCESS_KEY=dast-dummy-not-a-real-secret
AWS_S3_BUCKET=dast-dummy-bucket
AWS_S3_REGION=dast-dummy-region
AWS_S3_ENDPOINT=http://s3.example.invalid'
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
            # Boot dummies for the S3 file-storage config: run 33863826945 loud-skipped
            # with the container log reading `[Nest] ERROR [ExceptionHandler] TypeError:
            # Configuration key "file.awsS3AccessKeyId" does not exist`.
            # MulterConfigService.createMulterOptions() (apps/engine/src/files/
            # multer-config.service.ts) runs at module registration — before any
            # request, let alone a file upload — and getOrThrow()s
            # awsS3AccessKeyId/awsS3SecretAccessKey/awsS3Endpoint/awsS3Region/awsS3Bucket
            # unconditionally, because FILE_DRIVER defaults to 's3' (libs/common/src/
            # config/file.config.ts) and none of those five has a default. The
            # browser-surface baseline never hit this: it seeds the product repo's own
            # .env.example, which defines them; dast-api/scan.sh does not seed that file
            # at all. The scan never uploads a file, so the values only need to exist
            # and parse — obviously-fake, not a real endpoint or key, since this
            # repository is public and a plausible-looking fake reads as a leak to
            # anyone (or any secret scanner) later.
            DT_EXTRA_ENV='AWS_S3_ACCESS_KEY_ID=dast-dummy-not-a-real-key
AWS_S3_SECRET_ACCESS_KEY=dast-dummy-not-a-real-secret
AWS_S3_BUCKET=dast-dummy-bucket
AWS_S3_REGION=dast-dummy-region
AWS_S3_ENDPOINT=http://s3.example.invalid'
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
            #
            # WEBHOOK_URL: run against tag 2025_R4_master_9a879f10 loud-skipped with
            # `Config validation error: "WEBHOOK_URL" is required`. Verified at that exact
            # commit (an ancestor of current master, only 3 commits behind it):
            # src/app.module.ts's ConfigModule.forRoot Joi validationSchema required it
            # alongside TELEGRAM_API_ID/TELEGRAM_API_HASH/DATABASE_URL. Current master tip
            # no longer requires it — "feat(remove unused env webhook_url)" (#58) dropped it
            # from that same schema three commits later, and this local clone (branch
            # NC2-2258, past that removal) greps clean, which is exactly why it looked
            # missing. Kept here anyway: an unused var costs nothing, and GHCR may still
            # serve an older tag built before the removal.
            DT_EXTRA_ENV='TELEGRAM_API_ID=12345
TELEGRAM_API_HASH=00000000000000000000000000000000
NOVATALKS_ACCESS_TOKEN=dast-dummy-dummy-token
ENCRYPTION_SECRET=dast-dummy-dummy-dummy-dummy-dummy
WEBHOOK_URL=http://engine.example.invalid/webhook'
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
            # env-token, confirmed in auth.middleware.ts: handleApiAccessToken always
            # queries `accessTokens.findFirst` against Prisma first, then separately
            # checks whether the header value is in app.apiAccessTokens
            # (API_ACCESS_TOKENS, comma-split in app.config.ts) — either one
            # authenticates the request, and the env-list match still succeeds even
            # though the query finds no row (an empty/irrelevant table). The DB lookup
            # always happens, never skipped or short-circuited — that is exactly why
            # this arm needs DT_NEEDS_DB=true despite seeding no token into a database.
            #
            # Health from health.controller.ts's /readyz, which checks Prisma and Redis —
            # /livez here only checks memory thresholds and reports healthy even before
            # the database connects, so it is the wrong probe for this repository
            # specifically. Both are excluded from the global "api/v1/dialer" prefix by
            # global-prefix.ts, so they stay unprefixed. Neither route exists at all
            # unless HEALTH_ENABLED=true: src/app.module.ts (line 55) only pushes
            # HealthModule onto the imports array inside `if (process.env.HEALTH_ENABLED
            # === 'true')`, a raw process.env check made before Nest ever builds a
            # ConfigService — an unset var here is a 404 on /readyz forever, reported as
            # "the image did not come up" rather than the missing module it is. Port is 3000: app.config.ts's
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
            # this app-scan needs a real NATS server up, not just the env var — and now
            # gets one: dast-api/action.yml's needs-nats input reaches scan.sh's
            # dast_bring_up_nats (dast-common.sh), the same bring-up dast/scan.sh's
            # browser-surface baseline already used.
            DT_NEEDS_NATS=true
            DT_AUTH_MODE=env-token
            DT_AUTH_HEADER=api_access_token; DT_AUTH_SCHEME_PREFIX=''
            DT_TOKEN_ENV_VAR=API_ACCESS_TOKENS
            # entrypoint.sh runs `npm run db:setup` itself (npm survives here — this
            # Dockerfile never prunes devDependencies) before exec, so no setup command
            # is needed.
            DT_SETUP_COMMAND=''
            DT_SWAGGER_ENABLE=false
            # HEALTH_ENABLED=true: see the DT_HEALTH_PATH comment above — without it
            # HealthModule is never imported and /readyz 404s for the life of the
            # container.
            #
            # AWS_S3_*: src/config/file.config.ts (line 4) defaults FILE_DRIVER to 's3'
            # with no fallback for the five awsS3* keys it reads unconditionally (lines
            # 6-10). ContactModule and DncListModule (both unconditional imports in
            # app.module.ts) each register MulterModule.registerAsync({ useClass:
            # MulterConfigService }), and MulterConfigService.createMulterOptions()
            # (src/config/services/multer-config.service.ts:16-30) builds the S3 storage
            # unconditionally for the 's3' driver, calling multerS3({ bucket:
            # this.configService.get('file.awsS3Bucket'), ... }) — multer-s3's own
            # constructor (node_modules/multer-s3/index.js:111-115) throws `Error('bucket
            # is required')` the instant that value is undefined. A registerAsync factory
            # runs at module init, i.e. before the app ever listens, so a blank bucket
            # crashes boot exactly like it did for novatalks.core's awsS3* getOrThrow —
            # same failure class, different call site (multer-s3's own constructor
            # instead of a getOrThrow), and previously undocumented for this arm: the
            # comment two blocks up in this same file about "novatalks.dialer (five
            # AWS_S3_*...)" describes the old, removed dast/scan.sh baseline arm, not
            # this dast-api one, which shipped without them.
            # Live pentest run 33873579035: the app connects to NATS, finds the
            # 'campaign' stream dast_bring_up_nats creates, then dies creating its own
            # push consumer — node_modules/nats/lib/jetstream/jsclient.js:365 throws
            # "push consumer requires deliver_subject". Traced the whole path
            # (nats.config.ts -> nats-config.service.ts's consumerOptions ->
            # @nestjs-plugins/nestjs-nats-jetstream-transport's
            # server-consumer-options-builder.js -> nats' own consumerOpts()): only
            # `deliverTo` (NATS_DELIVER_TO) feeds `opts.deliverTo(createInbox(...))`,
            # which is what sets `deliver_subject`; jsclient.js's subscribe() throws
            # only when that is absent. NATS_DELIVER_GROUP and NATS_DURABLE feed
            # opts.deliverGroup()/opts.durable(), both no-ops when unset — the resulting
            # consumer is a plain ephemeral push consumer with no queue group, which is
            # all a single short-lived scan container needs. Added NATS_DELIVER_TO only;
            # the other two are not dereferenced by anything that can crash boot, so
            # adding them here would be unused ballast. NATS_STREAM_ENABLED stays unset
            # (nats.config.ts:16 default false) on purpose: it would make the app itself
            # call setupStream() with NATS_STREAM_NAME/NATS_SUBJECTS, and the stream this
            # arm already relies on is the one dast_bring_up_nats creates once, not one
            # the app re-declares.
            #
            # The now-removed browser-surface arm for this repository never hit this:
            # dast/scan.sh seeds the whole product-repo .env.example (its "DAST env
            # file" step), which carries NATS_DELIVER_TO as a real line, into the
            # container. dast-api/scan.sh has no such step — DT_EXTRA_ENV below is the
            # only environment the app-scan container gets beyond the image's own
            # defaults, so anything .env.example would have supplied has to be listed
            # here by hand. That asymmetry is the actual bug class; this is one instance
            # of it.
            #
            # dast-dialer-messages is deliberately outside the stream's own subject
            # space: nats.config.ts's streamConfig.subjects is NATS_SUBJECTS
            # (campaign.* below), and createInbox() turns this into
            # "dast-dialer-messages.<nuid>" — never a "campaign.*" match, so the
            # consumer's own deliver subject can never be re-ingested by the stream it
            # reads from (a self-feeding JetStream loop).
            DT_EXTRA_ENV='NATS_SUBJECTS=campaign.*
HEALTH_ENABLED=true
NATS_DELIVER_TO=dast-dialer-messages
AWS_S3_ACCESS_KEY_ID=dast-dummy-not-a-real-key
AWS_S3_SECRET_ACCESS_KEY=dast-dummy-not-a-real-secret
AWS_S3_BUCKET=dast-dummy-bucket
AWS_S3_REGION=dast-dummy-region
AWS_S3_ENDPOINT=http://s3.example.invalid'
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
        #
        # This is a decision, not an oversight: novatalks.geoip-api gets no DAST
        # coverage at all — no baseline, no api-scan, no pentest — permanently, for the
        # two reasons above. It keeps Trivy, Semgrep and secret detection. See CLAUDE.md
        # and docs/sast-dast.md for the recorded exclusion; it is also why it is not
        # offered in ci-dast-pentest.yaml's repository dropdown — a choice that always
        # fails loudly here is worse than not offering it.
        *)
            echo "::error::No DAST configuration for '${repo}' on the '${surface}' surface. Add an arm with its port, health path and auth read from that repository's own code — a guessed value scans nothing and reports it clean."
            return 1
            ;;
    esac
}
