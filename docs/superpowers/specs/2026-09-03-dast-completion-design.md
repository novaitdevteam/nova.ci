# DAST completion: no silent skips, and a real active scan

**Date:** 2026-09-03
**Status:** approved, awaiting implementation plan
**Supersedes nothing.** Extends `2026-09-02-dast-api-connectors.md` (the telegram pilot).

## Why

Two things are unfinished, and they are the same thing seen from two ends.

**The api-scan does not actually scan.** Every live run so far has ended
`⚠️ not run — database setup failed`. The cause is now known and fixed on `main`
(PR #38), but only two repositories are wired at all, and three of the remaining four
cannot use the pilot's approach: `npm prune --omit=dev` removes their seeder from the
image entirely.

**Nothing we run is a penetration test, and the reports should stop implying otherwise.**
All three ZAP modes are passive. `zap-api-scan.py` runs with `-S` (safe mode);
`zap-baseline.py` has no active scanner at all. We report header and cookie hygiene and
call it DAST. Both triage registers are empty, so no DAST finding can red a build even
in principle.

## What this delivers

1. **Zero `not run` verdicts** across all eight candidate repositories, each proven by a
   live run — the plan's exit criterion, not an aspiration.
2. **An active scan** that sends real attack payloads: injection, traversal, and the rest
   of the ZAP active rule set, authenticated, against both the API surface and the
   browser surface.

## Non-goals

- **This is still not a penetration test.** An active scanner finds injection classes and
  misconfiguration. It does not find IDOR, privilege escalation, business-logic flaws or
  chained exploits, because it has no model of intent. That gap closes with a human
  engagement, not with CI. The reports must keep saying so.
- No new automatic scanning. The active scan is manual only (D2).
- No changes to product-repository caller workflows.

## Decisions

### D1 — Two scan modes on the existing actions, not a new action

`dast/action.yml` gains `scan-mode: baseline | full`; `dast-api/action.yml` gains
`scan-mode: passive | active`.

In `full`, `dast/scan.sh` runs `zap-full-scan.py` in place of `zap-baseline.py`, passes
`-j` (the modern client spider), reads `zap-full-scan.conf`, and takes a longer timeout.
In `active`, `dast-api/scan.sh` drops `-S`.

*Everything else is untouched* — boot, seed, auth, the tally parse, the four outcomes.
This is verified, not assumed: `zap-full-scan.py` prints the identical tally line
(`zfs.py:480`) and uses the identical exit ladder (`0` passes, `1` FAIL findings, `2`
warnings without `-I`, `3` exception or nothing ran). `dast-common.sh` needs no change.

A fourth near-duplicate action would be the divergent-copy hazard `dast-common.sh` exists
to remove.

### D2 — The active scan is manual, and lives in nova.ci

A new `ci-dast-pentest.yaml`, `workflow_dispatch` only, shaped exactly like
`ci-dast-live-baseline.yaml`. No `schedule:`, no build-workflow job, no tag trigger.

Three reasons, in order:

1. It attacks. An attacking scan should be a decision somebody makes, with a timestamp
   and an actor against it, not something that happens because a branch was pushed.
2. It takes 30-60+ minutes. In a build that is intolerable — build wall-clock is already
   the thing this repository is actively cutting.
3. A `schedule:` trigger cannot live in a reusable workflow, and product-repository
   callers are not ours to edit.

It runs on `ubuntu-latest` and pulls the image from GHCR, so it costs **no Hetzner runner
and adds nothing to any build**.

### D3 — No free-text target, ever

Inputs are `repository` (a `choice` of the eight), `surface` (`api` | `browser`),
`target` (`ephemeral` | `live`, defaulting to `ephemeral`), and `confirm`.

`ephemeral` resolves to `http://127.0.0.1:<port>` against a container this workflow
started and kills. `live` resolves through a one-host `case`, exactly as
`ci-dast-live-baseline.yaml` already does. There is no input that accepts a URL, so there
is no input that can point an attacking scanner somewhere it must not go.

### D4 — The live target is a deliberate, recorded act

An active scan against a live host performs **real writes and deletions**: entities
created, settings changed, data possibly broken. The allowlisted host
(`novatalks-security.cloud.novatalks.com.ua`) is a dedicated security-testing instance,
not production, and that assumption is load-bearing — adding any other host is its own
decision, not a runtime choice.

Guards, all of them cheap and none of them optional:

- `ephemeral` is the default.
- `confirm` must equal the host name literally when `target: live`; otherwise the job
  fails **before** anything is scanned.
- The report, the job summary and the notification each carry
  `⚠️ LIVE TARGET — data was modified` and `github.actor`.

### D5 — Per-repository arms are read from each repository's code

Eight arms, one per repository, each carrying port, health path, spec path, auth mode,
header and prefix, token acquisition, and extra environment.

| Repository | Surface | Auth mode | State |
| --- | --- | --- | --- |
| `novatalks.core` | api + browser | `login` | wired, verified |
| `novatalks.ui` | browser | ZAP context (form login) | new |
| `nova.botflow` | browser | to be read | new |
| `nova.chatsconnector.telegram-client-api` | api | `db-token` | wired |
| `nova.chatsconnector.whatsapp-client-api` | api | **`db-insert`** | new mode |
| `nova.chatsconnector.signal-client-api` | api | **`db-insert`** | new mode |
| `novatalks.dialer` | api | **`env-token`** | new mode |
| `novatalks.geoip-api` | api | to be read | new |

The D7 rule from the pilot spec stands and is the reason this table has "to be read" in
it rather than a guess: **every value is verified against that repository's own code — the
Dockerfile, the guard, the schema — never inferred from a sibling.** Guessing has already
cost two failed runs.

### D6 — Two new auth modes, and why the pilot's does not generalise

- **`db-insert`** (whatsapp, signal). Their Dockerfiles run `npm prune --omit=dev`, which
  removes `ts-node` and with it the seeder — it does not exist in the runtime image.
  `sequelize-cli` *is* a runtime dependency, so migrations run. So: migrate, then
  **insert our own token row**. Their `tokens` / `token_roles` schema is identical to
  telegram's Prisma mapping (`tableName`, `field: 'api_token'`, `field: 'role_id'`, column
  `role`), so one parameterised `INSERT` covers both.
- **`env-token`** (dialer). `auth.middleware.ts` accepts any token listed in
  `API_ACCESS_TOKENS`, which `app.config.ts` splits from the environment. No database, no
  seed, no SQL — hand it a token we generated.

### D7 — A separate triage register per scan type

`zap-full-scan.conf`, alongside the two that exist. The active scanner loads rules the
passive ones never reach, so the registers are not interchangeable — the same argument
that already separates `zap-baseline.conf` from `zap-api-scan.conf`.

All three stay empty of entries until somebody accepts a specific finding. An entry is a
risk-acceptance decision, not a CI change.

### D8 — Policy is unchanged

`warn-only` governs findings; a scanner that could not run reds the job; an application
that fails to boot is a loud skip. The active scan changes what is *found*, not what a
finding *means*.

## The failure this whole design exists to refuse

Stated once, because every decision above is downstream of it: **a scan that could not run
produces exactly the output a clean scan produces.** Semgrep with zero rules loaded
reports zero findings. A ZAP scan against an application that crashed on boot yields an
empty report. `gitleaks git --log-opts` exits 0 on a range that resolves to nothing. An
unauthenticated scan of an API returns a plausible number of plausible findings.

That last one is not hypothetical here — it is what `dast-api` was doing until PR #34.
The `-z` replacer value was unquoted, `shlex.split()` tore `Bearer <token>` into two
arguments, and every request went out with a token-less header. The scan would have
reported a normal result for an unauthenticated crawl.

So every mode added here carries a positive proof that it ran as configured, and every
such proof gets a mutation test that fails when the proof is removed.

## Verification

- Harness scenarios for both `scan-mode` switches: the right script is invoked, `-S` is
  present in `passive` and **absent** in `active`, `-j` is present in `full`, the right
  register is loaded.
- A mutation test per guard. A guard nobody has watched fail is a guard that measures
  nothing.
- **Live proof per repository.** The exit criterion is eight repositories with a non-
  `not-run` verdict and a non-zero operation or URL count. A green tick over zero
  operations is the failure above wearing a hat.

## Open, and deliberately so

- `nova.botflow` and `novatalks.geoip-api` arms are written after reading their code. If
  a repository has no authentication at all, its scan is unauthenticated and the report
  says so.
- `novatalks.ui`'s ZAP context (login form selectors) is the one genuinely unknown piece
  and may take longer than the other seven arms combined.
