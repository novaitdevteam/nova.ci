---
name: dast-target-wiring
description: Use when adding, verifying, or debugging a repository's entry in nova.ci's DAST target table (.github/actions/dast/targets.sh) — wiring a new repository or surface into dast-scan (ZAP baseline) or api-scan (authenticated ZAP), choosing an auth-mode, resolving a repository's real port/health-path/boot environment, or diagnosing a DAST "not-run"/boot-timeout loud skip for a specific repository.
metadata:
  author: novatalks
  version: '1.0.0'
---

# DAST Target Wiring

Wiring a repository into `.github/actions/dast/targets.sh` has been done five times. Each
time it was re-derived from scratch, and each wrong guess cost a live CI run — booting the
image, waiting for a timeout, and reading a loud skip that blamed the image for something the
table got wrong. This skill exists so the sixth time is not that.

## Scope

Use this for `.github/actions/dast/targets.sh`, `scripts/test-dast-targets.sh`, and the
`Resolve DAST target` / `Resolve api-scan target` steps that consume it. It is a sub-skill of
`nova-ci` — read `.agents/skills/nova-ci/SKILL.md`'s SAST/DAST section first for the invariants
this table has to satisfy, and `references/dast-baseline.md` / `references/dast-api-scan.md`
there for the mechanics each `DT_*` field feeds into.

## The one rule everything else follows

**Every value in an arm is read from that repository's own code, right now — never inferred
from a sibling, a schema in isolation, or last time.** `signal` was expected to match
`whatsapp` and did, on token schema and header. It did **not** match on health path (no health
controller at all — `/`, not `/health`) or boot environment (a `Joi` schema requiring five
`STORAGE_PATH`/`S3_*` vars whatsapp has no equivalent of). A guessed value does not crash: it
scans the wrong thing and reports it clean, which is worse than not scanning.

## The five things every arm decides

| Field | Question it answers | Where to look |
| --- | --- | --- |
| `DT_PORT` | What port does the container actually listen on? | The Dockerfile's `EXPOSE`, the app's port config default — but the **production Helm chart** (`novatalks.charts`) wins if it disagrees, since that is what actually runs. |
| `DT_HEALTH_PATH` | What proves the process is up? | A real `@Controller('health')`/`/livez`/`/readyz` route if one exists. If the chart probes over `tcpSocket` or there is no health controller at all, use `/` — the boot loop only needs *any* HTTP response, 404 included. Do not invent a `/health` route that isn't there. |
| `DT_NEEDS_DB` / `DT_NEEDS_NATS` | Does boot (not just some endpoints) depend on a database or broker connecting first? | Read `main.ts`/the entrypoint, not just a schema — `novatalks.dialer` needs NATS because `main.ts` `await`s `microService.listen()` before `app.listen()`, unrelated to any env var. |
| `DT_AUTH_MODE` + its header/scheme/SQL/env-var | How does this repository's own auth guard decide a request is authenticated? | The guard/middleware itself (see auth modes below), never assumed from another connector. |
| `DT_SPEC_PATH` (api-scan only) | Where is the OpenAPI/Swagger JSON served, and is it gated? | The Swagger setup call. If there is no spec at all, there is no api-scan arm — see "When to say no." |

Every arm sets **every** `DT_*` variable, even ones with no consumer for that surface yet, so
a stale value from the previous `case` branch can never leak forward.

## The four auth modes, and `none`

Read the connector's own auth guard/middleware before picking one — do not pattern-match on
what "looks like" a REST API:

- **`login`** — the app exposes a login endpoint; POST username/password, read the token from
  the response body. Used where the app itself issues short-lived session tokens
  (`novatalks.core`, `Authorization: Bearer`).
- **`db-token`** — a token already exists in the seeded database after the entrypoint's own
  `db:seed`; read it with a caller-supplied `SELECT`. Used where the seeder creates a
  super-admin token as part of normal boot and nothing needs writing (telegram).
- **`db-insert`** — no usable seeded token exists (or its role/lookup key is inconvenient to
  depend on); generate one and `INSERT` it directly with a caller-supplied statement,
  `%TOKEN%` substituted in. Used where the schema is known but relying on the seeder's own
  `findOrCreate` key is fragile (whatsapp, signal).
- **`env-token`** — the app's auth middleware accepts *any* token present in an environment
  variable, with no database row behind it at all. Used only when that is actually how the
  guard works (`novatalks.dialer`'s `API_ACCESS_TOKENS`) — verify this by reading the
  middleware, not by assuming "no visible token table" implies it. This is the one mode that
  must generate and `::add-mask::` its token **before the container starts**: the app reads
  the variable once, at its own startup, so a token acquired after boot (every other mode's
  approach) would authenticate nothing.
- **`none`** — the target has no authentication at all. Legitimate, not a placeholder: say so
  explicitly and scan unauthenticated, rather than inventing a mode that doesn't exist in the
  code.

An empty token from `login`/`db-token` (login failed, or the `SELECT` matched no row) is a
loud `not-run`, never a scan that proceeds unauthenticated. `db-insert` and `env-token` cannot
produce an empty token — both are generated locally, never read back — so their failure modes
are different: a failed `INSERT` (`db-insert`) or a missing `token-env-var` name (`env-token`,
a scanner-configuration error, not a runtime one).

## Where required variables hide beyond the validation schema

A repository's Joi/class-validator schema is not the only place a required variable lives.
Two boot failures came from module-registration code that runs before any request, which no
schema check catches by reading the schema alone:

- **`getOrThrow()` calls with no fallback, reached at module registration.**
  `novatalks.core`'s `MulterConfigService` `getOrThrow()`s five `file.awsS3*` keys the moment
  its module registers — before any file is ever uploaded, and invisible unless you trace
  what runs at import time, not just what a request handler needs.
- **A feature gated behind a raw `process.env` check made before any `ConfigService` exists.**
  `novatalks.dialer`'s `HealthModule` is only pushed onto the `imports` array inside
  `if (process.env.HEALTH_ENABLED === 'true')` in `app.module.ts` — no schema entry, no
  default, just a 404 on `/readyz` for the container's whole life if it's unset.
- **A third-party constructor that throws at init time.** `multer-s3`'s constructor throws
  `bucket is required` synchronously if the S3 bucket config is undefined, and
  `MulterModule.registerAsync` runs that factory at module init — so any module that
  unconditionally imports the module wired to it (even one your scan surface never touches)
  can crash the whole container before it listens.

The check that catches these: **trace what actually executes between process start and the
health route responding** — every module imported unconditionally, every `registerAsync`
factory, every top-level `getOrThrow`/`process.env` read — not just the file named
`*validation*` or `*schema*`.

## Fake values must be structurally valid and obviously fake

Any dummy value that reaches a validator (an email, a bucket name, an endpoint URL) must pass
that validator's syntax check and must be unable to resolve to anything real.
`nova-ci-apiscan@local` failed the engine's own `isEmail` check because `@local` has no
top-level domain — the container died mid-boot and the job spent 300 seconds blaming the
image for a bad input instead. The fix, and the pattern to repeat: `@example.invalid` — RFC
2606 reserves `.invalid` for exactly this, so it always passes an email/URL syntax check and
can never be a live mailbox or host. Do not make a dummy "more realistic" — `TELEGRAM_API_HASH`
is kept as identical repeated hex characters on purpose, because a plausible-looking fake
would trip Gitleaks' entropy heuristic and red the required `secret-scan` check, and this
repository is public, so nobody reading a fake later can tell it from a leak unless it is
obviously fake.

## When to say no

Not every repository can be wired, and inventing an arm anyway is worse than refusing:

- **No OpenAPI/Swagger spec → no `api-scan` arm.** `api-scan` is spec-driven with no spider
  fallback; an arm with no spec to read would loud-skip forever and add nothing but a
  false sense of coverage. `novatalks.uspacy.connector` and `novatalks.geoip-api` are excluded
  for exactly this.
- **No auth at all is a legitimate `none` arm for `api-scan`** (if a spec exists), but combined
  with no spec it means no DAST coverage at all — `novatalks.geoip-api` gets neither `dast-scan`
  nor `api-scan` nor the pentest workflow, by explicit decision, recorded in `CLAUDE.md` and in
  `targets.sh`'s own comment.
- **No real browser surface → no `dast-scan` (baseline) arm.** The ZAP baseline is a browser
  tool; against a headless JSON API it finds a handful of response headers and nothing a
  browser would. That is why the six headless repositories were removed from the baseline on
  2026-09-01 in favor of `api-scan`.
- Say so in the PR/commit description rather than leaving a silent gap — the next person
  reading `targets.sh`'s `case` should not have to wonder whether a repository was forgotten
  or excluded on purpose.

## Procedure

1. **Read the repository's own boot path**, not its schema file alone: the Dockerfile's
   runtime stage (does it ship `npm`, or only compiled JS — decides whether a `setup-command`
   is even possible), the entrypoint script (does it already migrate/seed itself — if so,
   `setup-command` stays empty; a second migration over `docker exec` buys nothing and can
   race the entrypoint's own), and every module registered unconditionally at startup (see
   "Where required variables hide" above).
2. **Read the health route and the production Helm chart** (`novatalks.charts`) for the real
   port and health path — chart wins over a code default when they disagree, since it is what
   is actually deployed.
3. **Read the auth guard/middleware** to pick one of the four auth modes (or `none`), and read
   the exact header name, scheme prefix, and (for `db-token`/`db-insert`) the real table/column
   names and role value — copy nothing from a sibling connector without checking.
4. **Check for an OpenAPI/Swagger spec** if wiring `api-scan`: find the `SwaggerModule.setup`
   call, note its path, and note whether serving it is gated behind an env var
   (`swagger-enable` input) or unconditional. No spec means no `api-scan` arm — see "When to
   say no."
5. **Write the arm** in `.github/actions/dast/targets.sh`: set every `DT_*` variable
   explicitly, and comment each non-obvious value with the file and reasoning that justifies
   it — the comment is what stops the next reader (or the next repository "expected to match
   this one") from re-deriving it from scratch, or worse, copying a value that happened to be
   wrong for a reason specific to this repository.
6. **Bridge every `DT_*` you set to a real consumer.** A value set in `targets.sh` but never
   emitted by the `Resolve DAST target`/`Resolve api-scan target`/pentest `Resolve target`
   step, or never read by `dast/scan.sh`/`dast-api/scan.sh`, produces a scan that looks
   configured and is not — this exact gap happened with `DT_ZAP_CONTEXT` before the resolve
   steps caught up. If you add a field, grep for where the existing ones are emitted and read,
   and add it in the same places.
7. **Add a scenario to `scripts/test-dast-targets.sh`** asserting the new arm's shape (the
   existing checks are the pattern to copy) — this is the offline check that a typo or a
   missing `DT_*` fails fast, without a live run.
8. **Run `./scripts/validate.sh`.** It runs the offline self-checks but cannot boot a real
   container — treat it as necessary, not sufficient.
9. **Expect the first live dispatch to fail, and budget for it.** A live boot-failure loud
   skip is normal the first time — the report names the reason (`not-run — <reason>`); read
   it, fix the specific missing/wrong `DT_*` value, and re-dispatch. Every arm currently in
   `targets.sh` took at least one such round; some of the harder ones (`novatalks.core`'s two
   arms, `novatalks.dialer`'s NATS consumer) took several, each about five minutes for the
   image to boot, fail, and report.

## Reference

- `.github/actions/dast/targets.sh` — the table itself; read an existing arm's comments before
  writing a new one, and add rationale comments at the same density.
- `scripts/test-dast-targets.sh` — how an arm's shape is asserted offline.
- `docs/sast-dast.md` — the narrative reasoning, the auth-mode section in full, and the live
  proof log.
- `CLAUDE.md`'s DAST invariants — the rules that must never be re-broken, including the
  per-repository exceptions this table encodes.
- `.agents/skills/nova-ci/references/dast-baseline.md` and
  `.agents/skills/nova-ci/references/dast-api-scan.md` — what each `DT_*` field feeds into on
  the scanning side, and the shared mechanics (`dast-common.sh`) an arm can rely on.
