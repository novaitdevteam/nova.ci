# Parameterised API scanning for the connectors — pilot on telegram, then scale

**Date:** 2026-09-02
**Branch:** `feat/dast-api-connectors`
**Status:** approved for planning

## Problem

The authenticated `api-scan` (shipped in #28) is hardcoded to `novatalks.core`: it logs in
at `POST /auth/sign_in`, takes a JWT, and injects `Authorization: Bearer <jwt>`. That is
the engine's auth model. The four OpenAPI-bearing connectors —
`nova.chatsconnector.{telegram,whatsapp,signal}-client-api` and `novatalks.dialer` — lost
their (near-worthless) baseline DAST when it was narrowed to the three browser-surface
repos on 2026-09-01, and their real coverage was tracked to this expansion. But their auth
is **structurally different** from the engine's, verified in the telegram connector's code:

- The scheme is `api_access_token` — an `apiKey` in a **request header of that name**
  (`setup-swagger.ts:10-14`), not `Authorization: Bearer`.
- The token is **not** minted by a login call. It is a row in the database
  (`auth.guard.ts:28`: `prisma.token.findUnique({ where: { apiToken } })`), created by the
  seeder with a **random** value (`prisma/seed.ts:53`, `getRandomToken()`) — so it cannot
  be set the way the engine's `DEFAULT_USER_PASSWORD` sets the admin password.
- Swagger is served **unconditionally** (`main.ts:27`, no `SWAGGER_ENABLE` gate), at
  `/api-docs` (JSON at `/api-docs-json`, to be confirmed on the first live run).

So `api-scan` cannot scan a connector as it stands. The fix is to make the two things that
differ — how the token is acquired, and how it is injected — into inputs, prove the new
`db-token` path on one connector (telegram), then scale to the other three by
configuration rather than new code.

## Scope

**Phase 1 (this spec's deliverable): parameterise `dast-api` and pilot telegram.**
- Add an auth mode to the `dast-api` action: the existing `login` path (engine) and a new
  `db-token` path (seed the DB, read the seeded admin token straight out of it).
- Add a configurable injected header (engine: `Authorization` with a `Bearer ` prefix;
  telegram: `api_access_token`, raw value, no prefix).
- Wire an `api-scan` job for `novatalks.core` **and** `nova.chatsconnector.telegram-client-api`
  on the `apiscan*` tag; core keeps `login`, telegram uses `db-token`.
- Confirm it on a live `apiscan-*` tag run against telegram.

**Phase 2 (tracked, planned after Phase 1 lands): the other three connectors.**
`whatsapp` and `signal` are **Sequelize**, not Prisma — different seeder (`db:seed` via
sequelize-cli) and a different token table, to be read from each repo. `dialer` needs NATS
(`needs-nats`, the `campaign` JetStream stream) on top of postgres/redis. Each connector's
auth model is **verified against its own code before wiring** — telegram's shape is not
assumed to hold. Phase 2 is configuration on the parameterised action plus per-connector
verification, no new mechanism.

Out: the three browser repos' baseline (unchanged); active scanning; any product caller
edit; `uspacy`/`geoip` (no OpenAPI, out of API-scan scope permanently).

## Verified facts (telegram, from its code — not assumed)

- Auth header: `api_access_token`, `apiKey`/header (`setup-swagger.ts:10`).
- Guard reads the DB: `tokens.api_token` unique, joined to `token_roles.role`
  (`schema.prisma:91-113`, `@@map("tokens")` / `@@map("token_roles")`).
- Seeder path: `npm run db:seed` → `prisma/seed.ts`, creates a `SUPER_ADMIN` `token_roles`
  row and a `tokens` row with a random `api_token`; migrations via
  `npm run db:migrate` (`prisma migrate deploy`).
- Deterministic read (the token-acquisition for `db-token` mode):

  ```sql
  SELECT t.api_token FROM tokens t
    JOIN token_roles r ON t.role_id = r.id
    WHERE r.role = 'SUPER_ADMIN'
    ORDER BY t.id LIMIT 1;
  ```

- Boot deps: postgres + redis (`needs-db=true`); port 3000; no dedicated health route, so
  `/` (the same reasoning as the removed baseline arm). Swagger unconditional.

## Decisions

**D1 — `dast-api` gains an `auth-mode` input: `login` (default) or `db-token`.**
`login` is exactly today's engine path — a `POST` to a login route, JWT out of a response
header. `db-token` runs the repo's migrate+seed, then reads the seeded admin token from the
database with a caller-supplied `SELECT`. Both end with a single token string in one shell
variable; everything downstream (mask, inject, scan) is shared.

**D2 — the injected header is two inputs: `auth-header` and `auth-scheme-prefix`.**
Engine: `auth-header=Authorization`, `auth-scheme-prefix=Bearer ` (trailing space).
Telegram: `auth-header=api_access_token`, `auth-scheme-prefix=` (empty). The ZAP replacer
rule already takes an arbitrary header name and replacement string; this just stops
hardcoding `Authorization` and `Bearer`.

**D3 — the seeded token is read from the DB, not parsed from seeder output.**
The seeder prints the token (`console.dir`), but parsing stdout is fragile and per-repo.
A `SELECT` against the postgres container the action already started is robust and
generalises: "seed, then read the admin token." The query is a per-repo input
(`token-sql`), because the table and role differ (telegram: `tokens`/`token_roles`;
the Sequelize connectors will differ again). An empty result is a **loud skip**
(`not-run`), never a scan with no auth.

**D4 — the acquired token is masked, whatever its source.**
`db-token`'s value reaches the CI log the same way the JWT did (the replacer echo through
`tee`). `::add-mask::` is applied to it before first use, exactly as for the JWT. The
seeder's own `console.dir` of the token also lands in the migrate/seed step output — that
step's stdout is discarded to keep it out of the log, matching how the engine's seed output
is handled.

**D5 — the job gate widens to a two-repo allowlist, each with its mode.**
`api-scan`'s `if:` becomes `contains(fromJSON('["novatalks.core","nova.chatsconnector.telegram-client-api"]'), …)`
on the `apiscan*` tag. A `Resolve api-scan target` step (mirroring `Resolve DAST target`)
carries one arm per repo: core → `login`, `/auth/sign_in`, `Authorization`/`Bearer `,
`SWAGGER_ENABLE=true`; telegram → `db-token`, the `SELECT` above, `api_access_token`/empty,
no swagger flag, `needs-db=true`. The default arm fails loudly, like the DAST one.

**D6 — the image is built fresh per tag, unchanged.**
A connector's `apiscan-*` tag builds its own image in the same run and scans exactly that;
no pulling a "latest dev" image. Identical to core, and to what the user asked about.

**D7 — each connector's auth is verified before wiring, never assumed.**
Telegram's `db-token`/`api_access_token`/`tokens` shape is telegram's. Phase 2 reads
whatsapp's, signal's and dialer's own guards, seeders and schemas first; the arm is written
from what the code says. A wrong SQL or header scans an unauthenticated 401 surface and
reports it as covered — the failure this design is built to avoid, so the empty-token loud
skip (D3) and the safe-mode `-S` invariant both stay.

## Assumptions

**A1** — telegram serves its OpenAPI JSON at `/api-docs-json` (NestJS default for
`SwaggerModule.setup('/api-docs', …)`). First live run confirms; an empty spec is a loud
skip, so a wrong path fails safe.

**A2** — `db:migrate` + `db:seed` bring telegram to a state where the `SELECT` returns one
row, on the same ephemeral postgres the action starts. If a migration needs an env the job
does not supply, the seed step fails and the scan is a loud skip, not a false clean.

**A3** — the telegram boot env matches the dummies established during the DAST rollout
(`TELEGRAM_API_ID`, `TELEGRAM_API_HASH`, `NOVATALKS_ACCESS_TOKEN`, `ENCRYPTION_SECRET`),
now supplied by the api-scan arm rather than the removed baseline arm.

## Impact surface

| File | Change |
| --- | --- |
| `.github/actions/dast-api/action.yml` | add `auth-mode`, `auth-header`, `auth-scheme-prefix`, `token-sql`, `swagger-enable` inputs |
| `.github/actions/dast-api/scan.sh` | branch on `auth-mode`; `db-token` = migrate+seed+`SELECT`; parameterise the replacer header/prefix; mask the token; discard seed stdout |
| `.github/workflows/ci-build-ntk-on-push-tags-build.yaml` | widen `api-scan` gate to two repos; add `Resolve api-scan target` with core + telegram arms |
| `scripts/test-dast-api-scan.sh` | scenarios for `db-token` (seed→SELECT→inject), empty-token loud skip, header/prefix parameterisation, mask emitted |
| `docs/sast-dast.md`, `CLAUDE.md`, both `SKILL.md` | document the two auth modes, the two-repo scope, and the per-connector-verification rule |

## Sequencing

Parameterise the action first (behaviour-preserving for core — its scenarios stay green),
then add the telegram arm, then a live `apiscan-*` run on telegram to confirm A1/A2.
Phase 2 (whatsapp, signal, dialer) is a follow-up plan once the pilot is proven.
