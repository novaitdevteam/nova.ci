# NC2-3092 follow-up: `novatalks.rag` in `api-scan` and in the integration-test route

Date: 2026-11-03 · Jira: NC2-3092 · Follows nova.ci#98 and #99, which wired rag into lint, unit tests, Gitleaks, Semgrep, deps-scan and Trivy.

## Intent

`novatalks.rag` should be covered like the other services: an authenticated ZAP API scan on request, and its integration suite on the test tags. Both were left out of #98 because neither fits the existing machinery as is. This design closes that gap, and adds the least new machinery that does it honestly.

## Goals

- An `apiscan*` tag on rag builds the API image and runs `api-scan` against it: authenticated, every route reached with a token that passes rag's own guard. The opt-in tag is the same one the four connectors use.
- `int-test`, `unit-test` and `full-test` tags on rag run its suites through `ci-build-ntk-on-push-tags-run-test.yaml`.

## Non-goals

- No browser baseline (`dast-scan`). rag is a headless API, so the rule in `.claude/rules/code-scanning.md` that limits the baseline to browser surfaces applies.
- No `ci-dast-pentest.yaml` entry. That workflow runs in nova.ci, with no rag checkout to read `init-db.sql` and the migrations from, so the setup step below would fail every time.
- No runner-sizing change. A rag test tag stays on `small` (cx33) like every non-core repository. If the suite proves too slow there, sizing it is a separate change, with its own `test-create-runner.sh` scenario.

## Anti-goals (a failure even if it runs)

- A scan that reports `clean` while its requests went out unauthenticated. Two cases matter: the token expired mid-scan (rag caps a token's lifetime at 300 s), and the tenant was never registered.
- A nova.ci copy of rag's roles, migrations or test credentials that can drift from rag. Whatever rag's own files say has to be read from rag's checkout, or, where rag hardcodes a value and gives no way to override it, matched once with a comment that names rag's source.
- A committed private key or high-entropy dummy. Gitleaks would red `secret-scan`, and nova.ci is public.

## Facts this design rests on (read from rag's code, 2026-11-03)

| Fact | Where |
| --- | --- |
| The API refuses to start if `DATABASE_URL`'s role is a superuser, has BYPASSRLS, or owns `knowledge_bases`. It must be `rag_app`. | `src/database/database-role.check.ts`, `role-attributes.ts` |
| Roles `rag_admin`, `rag_app`, `rag_system` and the `vector` extension come from `docker/init-db.sql`, run as superuser. | `docker/init-db.sql` |
| Migrations run as `rag_admin` via `DATABASE_MIGRATION_URL`. They are plain JS in `src/database/migrations`, and `.sequelizerc` points there. The API image carries `sequelize-cli` and `dotenv` in its production `node_modules`, but not the migrations. | `.sequelizerc`, `src/database/config.js`, `docker/migrate.Dockerfile` |
| Postgres has to be pgvector 0.8 or later: `pgvector/pgvector:0.8.7-pg16`. | `docker-compose.test.yaml` |
| Boot requires `JWT_PUBLIC_KEYS`, `AWS_S3_BUCKET`, and four Engine values: `ENGINE_INTERNAL_URL` (https under production), `RAG_JWT_PRIVATE_KEY` (P-256 PKCS#8 PEM), `RAG_JWT_KID`, `KMS_MASTER_KEY` (`{"kid":"<base64 of 32 bytes>"}`). Nothing contacts Redis, S3 or Engine before `listen`. | `env.validation.ts`, `engine.config.ts`, `search-use-case.service.ts:54` |
| Auth is ES256 only. The `kid` header selects a `JWT_PUBLIC_KEYS` entry `{"kid":{"iss","pem"}}`, and `iss` must match it. `aud` is `novatalks.rag`. Required claims: `iss sub tid scope iat exp`, with `exp - iat ≤ 300`. `tid` is a UUID that must exist in `tenants`. `scope` is space-separated: `kb:read kb:write kb:search`. | `src/shared/guards/jwt-auth.guard.ts`, `scopes.ts` |
| Tenants: `tenants (id, external_ref, …)`, no RLS. The tests insert rows directly. | migration `20261002100100`, `test/support/db.ts:51` |
| Health: `/health/live` (no I/O), port 3000. Spec at `/api-docs-json`, always on. | `health.controller.ts`, `setup-swagger.ts` |
| Integration tests overwrite every connection value with hardcoded ones: database `rag`, the three role/password pairs, MinIO `rag`/`rag-test-secret`, bucket `rag-kb`, host `127.0.0.1`. Ports come from `RAG_TEST_FOUND_RAG_{POSTGRES,REDIS,S3}_TEST_PORT` when preset, otherwise from `docker compose`. The tests migrate in `globalSetup`, but create neither the roles nor the bucket. HNSW builds need `shm` above 64 MB. | `test/support/test-env.ts`, `test-ports.ts`, `global-setup.ts`, `docker-compose.test.yaml` |

## Decisions

### D1. A fifth `api-scan` auth mode, `jwt-es256`

No existing mode signs a JWT. In `jwt-es256` mode, `dast-api/scan.sh`:

1. **Before the app container exists** (the same ordering `env-token` needs), generates one P-256 key pair with `openssl`. It masks every line of the private key, then hands the app the public key as `<token-env-var>={"nova-ci-dast":{"iss":"<claims.iss>","pem":"<SPKI>"}}`. `token-env-var` is reused; for rag it is `JWT_PUBLIC_KEYS`.
2. Replaces `%JWT_PRIVATE_KEY%` in `extra-env` values with that private key (real line breaks). This is how rag gets its `RAG_JWT_PRIVATE_KEY` without nova.ci committing one. *My call:* one key serves both purposes, because both are throwaway.
3. **After boot**, takes the token's `tid` from `token-sql`, run through psql with `ON_ERROR_STOP`: rag's arm inserts its tenant and returns the id. An empty result is `not-run`.
4. Signs `{"alg":"ES256","typ":"JWT","kid":"nova-ci-dast"}`.`<jwt-claims> + {tid, iat:now, exp:now+300}` with `openssl dgst -sha256 -sign`. It then converts the DER signature to JWS's 64-byte `r‖s`. One input, `jwt-claims`, carries the static claims as JSON (`iss`, `aud`, `sub`, `scope`). 300 s is rag's ceiling (`MAX_TOKEN_TTL_SECONDS`) and the mode's fixed lifetime. *My call:* one JSON field rather than four inputs.
5. **After ZAP**, if the scan ran longer than 300 s since `iat`, the outcome is `not-run` ("the scan outlived its token"), never `clean`.

Signing uses `openssl` alone, so the mode depends on nothing in the scanned image. The harness verifies a signature with `openssl` too, and also with `node` when present, so a wrong DER→raw conversion fails offline rather than as a 401 on a live run.

### D2. A `pre-boot-command` hook, and a `pg-image` field

- `pg-image` (`DT_PG_IMAGE`) feeds the `PG_IMAGE` override `scan.sh` already honours. Empty keeps the current core/16 split. rag's value is `pgvector/pgvector:0.8.7-pg16`, the same pin as rag's compose files.
- `pre-boot-command` (`DT_PRE_BOOT_COMMAND`) runs on the runner, in the workspace (the scanned repository's checkout), after postgres and redis are ready and before the app starts. It sees `DAST_IMAGE` and the resolved `DATABASE_USERNAME`/`PASSWORD`/`NAME`. Its output is captured. A failure is `not-run` with that output printed: the same rules `setup-command` follows, because it is the same kind of step.
- rag's arm uses it to (a) pipe the checkout's `docker/init-db.sql` into `psql` in `nova-pg` as superuser, and (b) run `sequelize db:migrate` in a throwaway container of the scanned image itself. The checkout's `.sequelizerc` and `src/database` are mounted read-only, and `DATABASE_MIGRATION_URL` is set to `rag_admin`. That is exactly what `docker/migrate.Dockerfile` does, with no second image to build and no copy of rag's SQL in nova.ci.

### D3. `extra-env` moves after the database block

Docker keeps the last `-e`, so today `extra-env` cannot replace `DATABASE_URL`. rag needs `DATABASE_URL` to be `rag_app`. `extra-env` moves to just before `NATS_SERVERS`, which stays last. No existing arm sets any key in the block it now follows (checked: core, telegram, whatsapp, signal, dialer).

### D4. rag's `targets.sh` arm (`api` surface)

- **Endpoints:** port 3000, health `/health/live`, spec `/api-docs-json`, `swagger-enable false`, `needs-db true`, `needs-nats false`.
- **Auth:** `auth-mode jwt-es256`, header `Authorization`, prefix `Bearer `, `jwt-claims` `{"iss":"engine","aud":"novatalks.rag","sub":"1","scope":"kb:read kb:write kb:search"}`. `sub` is numeric because the guard keeps only `^\d{1,9}$` subjects as the actor (`jwt-auth.guard.ts:25`). The token SQL is `INSERT INTO tenants (external_ref) VALUES ('nova-ci-dast:1') RETURNING id`.
- **`extra-env`:**
  - `DATABASE_URL=postgresql://rag_app:rag_app@127.0.0.1:5432/db_name`
  - `AWS_S3_BUCKET=dast-dummy-bucket`
  - `ENGINE_INTERNAL_URL=https://engine.example.invalid`
  - `RAG_JWT_KID=nova-ci-dast`
  - `RAG_JWT_PRIVATE_KEY=%JWT_PRIVATE_KEY%`
  - `KMS_MASTER_KEY={"dast":"AAAA…A="}`: 32 zero bytes, obviously fake and low-entropy.
- The `browser` surface keeps failing loudly: there is no baseline for rag.

### D5. Build workflow

- The `api-scan` job's repository list gains rag.
- The rag Dockerfile arm builds the API for `apiscan*` again (#98 made it fail while no scan existed).
- The three resolve steps (`Resolve api-scan target`, the pentest `Resolve target`, `dast-target`) emit the new keys, and `dast-api` takes them as inputs. `scripts/test-dast-targets.sh` already fails on a key set but not emitted or not read, so the pentest workflow reads them too, even though rag is not in its dropdown.

### D6. Integration-test route

- The switcher's test route gains rag for all three tags.
- The `unit-tests` job runs `npm test` on rag (it has no `test:unit`), `npm run test:unit` elsewhere.
- For rag, the `integration-tests` job:
  - starts `pgvector/pgvector:0.8.7-pg16` with `--shm-size=1g` and `POSTGRES_DB=rag`;
  - applies the checkout's `docker/init-db.sql`;
  - starts MinIO with rag's fixed test credentials and creates `rag-kb`. *Changed during implementation:* rag's pin (`minio/minio:RELEASE.2025-09-07T16-13-09Z`) no longer pulls — MinIO withdrew its images from Docker Hub and quay — so the server and `mc` are Chainguard's `cgr.dev/chainguard/minio` and `minio-client`, pinned by digest;
  - presets the three `RAG_TEST_FOUND_*_PORT` variables, so the tests never call `docker compose`. Compose is not used on the runners anywhere, so its presence there is unproven.
  - skips core's `.env.example` import. rag's tests overwrite it anyway, and a stray key is a risk with no upside.
- Credentials, database name and bucket are rag's hardcoded test values: matched, not chosen. The comment cites `test/support/test-env.ts`.

## Left to the builder

- Exact step names and wording of the notifier lines (they follow the existing lines).
- Harness scenarios: at least one each for the `jwt-es256` happy path (the token verifies against the public key and carries `tid`, `aud`, scope and `kid`), an empty `tid`, a scan that outlives the token, a failing `pre-boot-command`, `extra-env` overriding `DATABASE_URL`, and the private-key placeholder being substituted and masked.

## Verification

- `./scripts/validate.sh` with the new harness scenarios.
- **Live:**
  - an `apiscan-…` tag on rag's PR branch, which reaches the build route since tags route regardless of branch;
  - an `int-test-…` tag. A first-run loud skip is expected and is read, not retried blindly (`dast-target-wiring` step 9).
