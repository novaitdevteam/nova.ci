# Authenticated DAST: API scanning and a live-instance baseline

**Date:** 2026-09-01
**Branch:** `feat/dast-api-scan`
**Status:** approved for planning

## Problem

The ZAP baseline shipped in the scanner stack is a **browser-surface** tool. It probes
the root, follows what a spider finds, and reports header and cookie hygiene. That is the
right instrument for `novatalks.ui` and `nova.botflow` — the botflow run alone surfaced 14
alert types including a JS library with 13 CVEs — and the wrong one for the other seven
DAST repositories, where it only ever finds three browser headers on a JSON API that no
browser consumes.

Two gaps follow, and neither is a tuning problem:

1. **The engine's API is unscanned.** `novatalks.core` serves 341 operations across 250
   paths. **330 of them declare their own security** (`bearer`, `api_access_token`,
   `auth-widget`); only 11 are open. An unauthenticated scan reaches the 401 handler, not
   the API. The spider cannot help — verified on the live instance, **every non-existent
   path returns 200** because nginx serves the SPA `index.html` for anything unmatched, so
   a spider cannot tell a real route from an invented one. The machine-readable spec at
   `/api-docs-json` is the only authoritative route list.

2. **The container scan cannot see the real deployment.** The CI DAST scans the image in
   isolation over plain HTTP on `127.0.0.1`. On the live instance the same application sits
   behind Cloudflare and an nginx that serves the SPA. Measured on
   `novatalks-security.cloud.novatalks.com.ua`, the two surfaces disagree:

   | Header | `/` (nginx static) | `/auth/sign_in` (engine, helmet) |
   | --- | --- | --- |
   | Content-Security-Policy | absent | present |
   | Strict-Transport-Security | absent | present |
   | X-Content-Type-Options | absent | present |
   | Referrer-Policy | absent | present |

   The page a browser actually opens carries none of them. A container scan structurally
   cannot show this, because it never sees nginx or the ingress.

## Scope

Two independent deliverables in one branch. Neither touches an existing scanner.

**A — authenticated API scan in CI, `novatalks.core` only.** A new job, gated on a new
`apiscan*` tag, that brings up an ephemeral engine stack, migrates and seeds it, logs in as
the seeded admin, and runs `zap-api-scan.py` in **safe mode** against the engine's own
`/api-docs-json`. No live credentials, because the database is ours and dies with the job.

**B — unauthenticated baseline of the live instance.** A new `workflow_dispatch` workflow
that runs `zap-baseline.py` against an allowlisted URL through Cloudflare. No credentials —
the value is the nginx/ingress header surface, which needs no login. Not part of any
product repository's build; run by hand.

Out: no change to the nine existing DAST repositories, to the four live scanners, or to any
product caller. Active scanning (`zap-full-scan.py` without `-S`) is explicitly **not** in
this branch — it belongs on the same ephemeral stack as A, after A works and the triage
register has entries, and it is planned separately.

## Verified facts

Established by reading the code and probing the live instance, not from memory:

- Seeder creates a **deterministic** super-admin — `seeds.service.ts:76,79,283`:
  `email = DEFAULT_ADMIN_USER || 'support@novatalks.ai'`,
  `password = DEFAULT_USER_PASSWORD || '!P@ssw0rd'`, `type = UserType.SuperAdmin`, role
  `Administrator`. Both env vars are read directly, so the job sets its own values and no
  secret is involved. The seeder even logs the credentials itself (`:313`) — they are not
  secret by design.
- Login route is `POST /auth/sign_in` (**not** `/auth/login`), and it returns the JWT both
  as a `Set-Cookie: authentication=…; HttpOnly; Secure; SameSite=Lax` and in the
  `Authorization` response header. Confirmed live.
- Swagger is gated in production: `main.ts:58` serves it only when
  `app.swaggerEnable` is true, and `app.config.ts:28` reads that from `SWAGGER_ENABLE=true`.
  **The job must set it**, or `/api-docs-json` is empty.
- The spec at `/api-docs-json` is JSON, 250 paths / 341 operations,
  `securitySchemes: bearer, api_access_token, auth-widget`, no global security.
- The build image runs migrations and seed via `db:setup:prod`
  (`db:create:prod && db:migrate:prod && db:seed:prod`) — `package.json:45,46`.
  **The current DAST job does neither; it only boots the image.** A carries this itself.
- `zap-api-scan.py` accepts `-t <openapi url|file> -f openapi`, `-S` (safe mode: skip the
  active scan, passive only — `zap-api-scan.py:111`), `-c` (the same triage config grammar
  as baseline), and `-z "-config …"` to pass raw ZAP options (`:115,228`). Header injection
  is a `replacer` rule via `-z`.
- Cloudflare does **not** block scanner traffic: ZAP's user-agent, an empty UA and a
  browser UA all return 200 on the live host.

## Decisions

**D1 — A is a separate job on an `apiscan*` tag, not an extension of `dast-scan`.**
A 341-operation scan needs migrations, a seed and a login before ZAP even starts; folding
that into the per-build DAST job would make it large, core-specific, and run on every
trunk build for no reason. Its own tag makes the cost of a long run something you opt into.

**D2 — the seeded admin's credentials are generated in the job, not stored.**
The job sets `DEFAULT_ADMIN_USER` and `DEFAULT_USER_PASSWORD` to values it generates at
run time (`DEFAULT_USER_PASSWORD` from `openssl rand`), passes them to the seed step, then
uses them once to log in. They never leave the runner and the database is destroyed at job
end. Zero GitHub secrets, zero rotation. This is the whole point of scanning our own
ephemeral stack rather than a live one.

**D3 — safe mode is mandatory for A.** `zap-api-scan.py` active-scans by default. Against
341 operations with an admin token that means real `POST`/`PUT`/`DELETE` traffic. `-S` is
non-negotiable for this branch; the active variant is a separate, later decision on the
same stack, and it will need the triage register populated first.

**D4 — auth is a `replacer` rule, not a context file.** The job logs in once, captures the
JWT, and passes
`-z "-config replacer.full_list(0).description=auth -config replacer.full_list(0).enabled=true -config replacer.full_list(0).matchtype=REQ_HEADER -config replacer.full_list(0).matchstr=Authorization -config replacer.full_list(0).replacement=Bearer <JWT>"`.
Simpler than a context file, and it means the JWT is injected on every request without ZAP
needing to understand the login flow.

**D5 — B takes a target URL as a `workflow_dispatch` input, validated against an
allowlist.** The default and only initially-allowed target is the dedicated instance
`novatalks-security.cloud.novatalks.com.ua`. Any other value fails loudly. A free-text URL
field with no allowlist is how a scanner eventually points somewhere it must not; the
allowlist is a hard `case`, adding a host is a deliberate edit.

**D6 — both reuse the triage register and the tally/exit-code logic from `dast/scan.sh`.**
The counting, the `-c` config, the `^FAIL-NEW: [0-9]+\t` tally anchor and the `0|1|2` exit
ladder are correct and tested; A and B call the same shared code paths, not copies. Where
`zap-api-scan.py` differs from `zap-baseline.py` in output, the difference is verified live
before the harness encodes it — the recurring lesson of this stack is that a guard which
looks right can measure nothing, so nothing about api-scan's output format is assumed.

**D7 — SPA 200-for-everything is stated in the report, not worked around.** On the live
instance every unmatched path is 200. B's baseline will therefore spider invented routes
and report duplicate header findings. This is inherent to an SPA behind nginx and is noted
in the report header so a reader does not mistake volume for coverage. A does not have this
problem — it scans the spec's real routes, not the spider's guesses.

**D8 — honest naming.** Neither A nor B is a penetration test, and the docs say so.
Passive api-scan checks transport and header hygiene across real endpoints; it does not
find IDOR through `{accountId}`, privilege escalation, or business-logic flaws. Even the
later active scan is automated payloads against known classes, not an audit. The quarterly
evidence pack may cite these runs as automated coverage, never as a pentest.

## Assumptions

**A1** — the engine image boots to a serving state with `db:setup:prod` run against the
ephemeral postgres, on the same env the integration-test job already uses. If a migration
needs an env the job does not provide, the first run surfaces it; the scan fails loudly
(`not-run`) rather than scanning a dead app.

**A2** — `zap-api-scan.py`'s completed-scan output carries a tally line in the same shape
as `zap-baseline.py`. Not yet verified against a real run — first CI run confirms, and the
tally guard fails closed if it does not.

**A3** — 341 operations passive is slow but bounded on a `medium` runner. If a run exceeds
a sensible wall-clock, the spec's follow-up is to scope the spec by OpenAPI tag; not solved
pre-emptively.

**A4** — the live instance stays reachable and dedicated to this task. If it is torn down,
B has no target and is skipped, not failed.

## Impact surface

| File | Change |
| --- | --- |
| `.github/actions/dast-api/action.yml` | new — the API-scan composite action |
| `.github/actions/dast-api/scan.sh` | new — boot, migrate, seed, login, api-scan, report |
| `.github/workflows/ci-build-ntk-on-push-tags-build.yaml` | new `api-scan` job, gated on `apiscan*` |
| `.github/workflows/ci-dast-live-baseline.yaml` | new — `workflow_dispatch` baseline of the live instance |
| `.github/workflows/ci-build-trigger-switcher.yaml` | route `apiscan*` tags for `novatalks.core` |
| `scripts/test-dast-api-scan.sh` | new — offline scenario harness, `docker`/`curl` stubbed |
| `scripts/validate.sh` | register the new harness and guard |
| `docs/sast-dast.md`, `CLAUDE.md`, both `SKILL.md` | document A, B, the safe-mode invariant and the honest-reach limit |

## Sequencing

A first — it is self-contained, needs no external state, and delivers the larger coverage
gain. B second — smaller, but depends on the live instance staying up and on the leaked
credentials having been rotated. Active scanning is a separate spec after both land.
