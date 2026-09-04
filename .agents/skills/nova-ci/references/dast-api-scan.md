# DAST api-scan (authenticated ZAP) — depth

Referenced from `SKILL.md`'s "SAST and DAST Semantics" section. Read that section first. See
also `.agents/skills/dast-target-wiring/SKILL.md` for the procedure to wire a new repository
into this table, and `references/dast-baseline.md` for the shared mechanics (tally parse,
`0|1|2` exit ladder, `dast-common.sh`, `targets.sh`) this scan reuses.

## What it does

`dast-api/action.yml` + `scan.sh` boot the image on ephemeral postgres/redis, migrate and
seed, acquire a token, and run `zap-api-scan.py -f openapi` against the app's own
`/api-docs-json`.

## The four auth modes

**Parameterised auth**: `auth-mode` is `login` (POST username/password, read the token from
the response — `novatalks.core`, `Authorization: Bearer`), `db-token` (read the seeded token
straight out of the DB with a caller-supplied `SELECT` — telegram, injected raw under
`api_access_token`), `db-insert` (write a generated token into the DB with a caller-supplied
`INSERT`, `%TOKEN%` substituted in, `role_id` filled from
`SELECT id FROM token_roles WHERE role = 'super_admin'` — lowercase, per
`token-role.enum.ts`, unlike telegram's uppercase `SUPER_ADMIN` — for whatsapp/signal, whose
Dockerfiles `npm prune --omit=dev` away `ts-node`, but whose entrypoints still self-seed via
compiled JS (`node dist/scripts/run-seed.js up`), so a token exists either way; `db-insert`
writes its own rather than depending on the seeder's own `findOrCreate` key), or `env-token`
(generate a token before the app container starts and hand it in as
`-e <token-env-var>=<token>` — for `novatalks.dialer`, whose auth middleware always queries
`accessTokens.findFirst` first (never skipped — that query is why this arm still needs
`needs-db: true`), but also accepts any token present in the `API_ACCESS_TOKENS` env var,
which is enough on its own to skip the middleware's outbound call to the engine; no seed, no
stored row). Every other mode acquires its token *after* boot; `env-token` is the one mode
that must generate and `::add-mask::` its token before the container exists, right beside
`ADMIN_PASS` — the application only reads the variable once, at its own startup, so a token
acquired later would authenticate nothing. The header, scheme prefix and token
`SELECT`/`INSERT` are per-repo inputs; the token is masked with `::add-mask::` whatever its
source; an empty token (no login token, or the `SELECT` matched no row) is a loud `not-run`,
never a scan without auth — `db-insert` and `env-token` cannot produce an empty token (both
generated locally, never read back), so their own loud-skip/error paths differ instead:
`db-insert`'s is a failed `INSERT` (`not-run`, the migration never created the table),
`env-token`'s is a missing `token-env-var` name (a **scanner error** — nothing to generate a
token for).

There is a fifth value, `none`, for a repository with no authentication at all — see
`.agents/skills/dast-target-wiring/SKILL.md`.

## Safe vs. active mode

**Safe mode `-S` by default, `active` a deliberate exception** — a `scan-mode` input
(`passive` default, `active`) reaches `scan.sh` as `DAST_API_SCAN_MODE`; only `active` drops
`-S`, turning the tool into a real-writes active scan against the seeded API. Safe only
because the stack is the ephemeral one this action starts and kills, so `active` is never the
default and an unrecognised mode is a scanner error, not a silent fallback.
`scripts/test-dast-api-scan.sh` (87 checks) asserts `-S` on the default, its absence under
`active`, and the mask — including a mutation check that a mismatched `env-token` value (ZAP
holding a different token than the one handed to the app) fails the harness, since that scan
would look authenticated while checking nothing.

## The seed identity

The seed admin password is `openssl rand`-generated per run and stored nowhere
(`DEFAULT_ADMIN_USER` / `DEFAULT_USER_PASSWORD`). **`DEFAULT_ADMIN_USER` must be a
syntactically valid email at a domain that can never be real**: `@local` failed the engine's
own Sequelize `isEmail` seeder validation (`require_tld: true`) and killed the container
mid-boot, reported as a boot timeout rather than the bad input it was (confirmed live, run
33761248644) — it is now `nova-ci-apiscan@example.invalid`, the RFC 2606 reserved domain. ZAP
echoes the token-bearing replacer rule to its own stdout — a public repo's persisted step log
— which is why the mask, plus the console file deleted on exit. Serving the spec can be
conditional (`swagger-enable`: core needs `SWAGGER_ENABLE=true`, telegram serves it
unconditionally and sets `false`); an empty spec is a loud `not-run`. Same four outcomes and
tally parse as the baseline; its own triage register `dast-api/zap-api-scan.conf`, not the
baseline's.

## The `-z` replacer quoting bug

**Keep the `-z` replacer values wrapped in literal single quotes.** `zap-api-scan.py` puts the
whole `-z` string through `shlex.split()` before handing it to ZAP (`zap_common.py:
add_zap_options`), so an unquoted `replacement=Bearer <token>` arrives as *two* arguments: ZAP
sets the header to a bare `Bearer` and drops the token as a stray positional, and the scan
runs **unauthenticated while reporting a perfectly plausible result**. `db-token` connectors
hid it because their prefix is empty. The harness reproduces ZAP's own `shlex.split` rather
than grepping the raw string — grepping passes either way, which is how this survived review.

## Each connector's auth model, verified independently

**Each connector's auth model is read from its own code before its `targets.sh` arm is
written.** Telegram's `db-token`/`api_access_token`/`tokens` shape was not assumed for the
Sequelize connectors (whatsapp, signal) or dialer, each verified independently with its own
token storage, header and seed path — including signal, expected to match whatsapp and
checked anyway rather than copied (same `roles.guard.ts` header, same
`token.model.ts`/`token-role.model.ts` schema, but no health controller at all and a `Joi`
env-validation schema whatsapp has no equivalent of). Dialer's was verified this way:
`src/auth/auth.middleware.ts` accepts any token in `app.apiAccessTokens`
(`src/config/app.config.ts` splits it from `API_ACCESS_TOKENS`), which is why it gets
`env-token` rather than `db-token`/`db-insert` — there is no database row behind it at all.
See `.github/actions/dast/targets.sh`'s comments on each `api` arm for the full per-repository
evidence — that file, not this one, is the canonical record and the one to update.

## Reach and honesty

The authenticated `apiscan*` scan adds real logged-in endpoints but stays passive — no IDOR,
no privilege escalation, no business-logic flaw — and is not a pentest either.

## Test coverage

Changing `scan.sh` means adding a scenario to `scripts/test-dast-api-scan.sh` in the same
change.
