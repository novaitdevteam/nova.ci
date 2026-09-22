# E2E against an ephemeral stack: Plan

**Spec:** [`../specs/2026-09-18-e2e-ephemeral-stack.md`](../specs/2026-09-18-e2e-ephemeral-stack.md)
**Status:** in progress — Steps 0-3 done. `@CI` is **green against the ephemeral target**
(run 35605382826, 2026-09-21: one test, 55.8s, on a stack the run booted and destroyed).
Step 1b next (campaigns end to end), then Step 4's measurements
**Date:** 2026-09-18

Each step ends in something observable. A step whose verification cannot fail is not done —
it is the guard-that-measures-nothing this repository refuses everywhere else.

## Step 0 — Answer the four open questions first

Nothing below is worth building if the UI cannot be pointed at a different engine, or if the
canonical BotFlow flow cannot transfer a conversation.

- ~~How the UI takes its configuration~~ **answered**: runtime, from every `VITE_APP_*` in the
  environment; the container proxies nothing, hence the front proxy in D15, and the value set
  comes from a production configmap per D16.
- ~~Which engine keys are required~~ **answered**: `helm template` renders all of them offline,
  so the stack renders the chart instead of curating a list (D17). What is left to verify is
  which values must differ on a runner. **Verify:** the rendered engine env boots the container
  to `/readyz` 200 with only hosts, ports and `FILE_DRIVER` overridden.
- ~~Whether the canonical flow transfers a conversation~~ **closed by decision**: it does not,
  so the stack copies the stand's live flows at boot instead (D7). Nothing to measure.
- **Verify overall:** a written note of the four answers, in the spec's open-questions table.

Step 0 is therefore closed. The flow-parity risk it existed to catch is gone by construction:
the ephemeral stack runs the stand's own flows.

## Step 1 — `stack.sh`: bring the stack up and tear it down

A single script in `.github/actions/e2e-stack/`, sourcing `dast-common.sh` for the NATS
bring-up rather than repeating it, and rendering the chart for every container's environment
(D17) rather than carrying its own copy of it.

- `up`: network, postgres, redis, nats, engine (wait `/readyz`), the three SQL settings and
  the AgentBot token, dialer (wait `/readyz`), botflow (wait `/redbot/`), ui, proxy (wait `/`).
- Environments come from `helm template` of the chart at `chart_ref` (D17), one `--env-file`
  per container, with only hosts, ports, the three UI URLs and the S3 settings overridden.
- `down`: always runs, prints `docker logs` for every container when the suite failed.
- Fails loudly with the container's own log on any wait that expires — never "the image did
  not come up" with no evidence.
- **Verify:** run it on a runner by hand; `/readyz`, `/redbot/` and the UI all answer; then
  `down` leaves no container, no volume and no network behind (`docker ps -a`, `docker volume ls`).
- **Done 2026-09-21**, probe run 35584025381: engine 38s, dialer 10s, botflow 6s, ui 4s,
  proxy 2s — about a minute from postgres to a served origin, with every path answering the
  same through the proxy as on its own port.
- Six faults, found only by running it, and four of them looked identical from outside — a
  wait that expired with nothing to read: campaigns forced on past the flag that renders the
  chart's NATS keys; `PORT` where the dialer reads `APP_PORT`; `FILE_DRIVER=local` against a
  storage map holding only `s3`; and the image's own `settings.js`, which leaves Node-RED on
  `/` rather than `/redbot`.
- The other two are the ones worth keeping in mind, because both **passed as green**: botflow
  answering 404 on its admin root, and an nginx already on the runner's 8080 answering the
  proxy's health poll for three runs. `wait_http` counting any answer as up is right for a
  health path and wrong for a server that answers everything or a port somebody else holds.
  Hence the origin on 18080, the port guard, and two assertions — botflow's admin root is not
  404, and `/redbot/` through the proxy matches what botflow serves directly.
- A third of the same kind was in the guard itself: `curl -w '%{http_code}' || echo 000`
  writes `000000` on a free port. One `http_code` helper now, `|| true` for `set -e` only.

## Step 1b — NATS, the dialer and campaigns

The one area the lab cannot cover, so it is worth its own step rather than a line in the
bring-up.

- `dast_bring_up_nats` from `dast-common.sh` (never a second copy): the broker, the health
  poll and the `campaign` stream.
- Engine with campaigns on, started **after** NATS — it awaits the connection before it
  listens, which is exactly how the lab's engine sat `0/1` for nine minutes when this was
  tried there. Switch it on in `values.ephemeral.yaml` (`engine.nats.enabled: 'true'` plus
  `ENGINE_NATS_SERVERS`), never as an `-e` on the container: the chart renders
  `NATS_DURABLE` / `NATS_DELIVER_TO` / `NATS_SUBJECTS` only under that flag, and the feature
  without those keys builds a JetStream consumer out of `undefined` and never listens. Step 1
  hit exactly that on 2026-09-21, and saw it as a 900s silence rather than an error, because
  `main.ts` buffers its logs until after the microservice is up and its `uncaughtException`
  handler logs into that same buffer.
- Dialer from its `targets.sh` arm: `HEALTH_ENABLED=true` or `/readyz` 404s forever,
  `NATS_SUBJECTS`, its own database, `AWS_S3_*` dummies; its entrypoint runs `db:setup`.
- **Verify:** the engine reports the campaign feature to the UI (the sidebar item is a link,
  not a promo button — the exact thing QANT-49 asserts), `/readyz` on the dialer answers, and
  a campaigns spec that is excluded on `lab` passes here.

## Step 2 — Flows for an ephemeral BotFlow

- Copy the live document from the stand's Node-RED admin API, rewrite the webhook base to the
  engine's container name, then run the existing slot reconcile for N workers against the
  ephemeral BotFlow.
- Log the node count and a hash of what was copied, so a red run can be told from a flow change.
- A stand that cannot be read at boot fails the run loudly; there is no fallback document.
- Deploy it through the Node-RED admin API, then wait for every `/telegram|viber|messenger/<n>`
  route to answer.
- **Verify:** with `WORKERS=4`, all 12 routes answer; a message posted to `/telegram/1` creates
  a conversation and it reaches a team.

## Step 3 — Wire the target into the workflow

- `target` input (`lab` default, `ephemeral`), plus `engine_tag` / `ui_tag` / `botflow_tag`,
  each defaulting to the tag the stand runs. The registry and repository are fixed in the
  workflow per component, so the form cannot point the runner at an arbitrary image.
- `ephemeral` resolves `ENV_URL` and `BOTFLOW_URL` to the published localhost ports and
  ignores nothing silently: `reset_stand` with `target: ephemeral` fails the step with a
  message, per D14.
- `runner_size` resolves to `e2e-medium` for `target: ephemeral` (D11). The pool itself
  already exists — `novatalks.tests` was split out of the build pool on 2026-09-18 — so this
  is one arm mapping the target to the size, with its scenario in
  `scripts/test-create-runner.sh` in the same change, per the repository's own rule.
- `concurrency` keys on the run id for `ephemeral`, on `env_url` for `lab` (D12).
- **Verify:** `@CI` green on `target: ephemeral`; the same tag still green on `target: lab`;
  two ephemeral runs at once both finish (no queueing).
- **Done 2026-09-21**, run 35605382826. Eight faults between the stack coming up and the suite
  passing, and the three that cost the most were the ones that looked like something else:
  - nginx drops headers containing underscores, and the Engine's credential is
    `api_access_token`. Every API call answered 401 while the token itself was valid — proven
    valid by a check that sent it straight at the container, past the proxy that was eating it.
  - the seeded admin password had no uppercase, against the engine's own default policy, so
    creating an agent answered 422 and read as a product fault rather than an input.
  - the seeds create the AgentBot **and** a random token for it unless `AGENTBOT_INBOX_TOKEN`
    is set, which the chart never renders. Adding the right token as a second row changed
    nothing about which one the engine sent, so BotFlow ignored every agent-bot call in
    silence: conversation created, bot asked, no answer, no error anywhere.
  All three were found by rendering the chart with the lab's values beside this stack's and
  diffing the result — not by reading logs, which had been exhausted twice by then.

## Step 4 — Measure, then decide the default

- `@smoke` and `@e2e` on both targets, recording wall time, boot time, load and pass counts,
  in the table in `docs/tests.md` next to the existing measurements.
- **Verify:** the numbers are in the docs and the default target is chosen *from* them, not
  before them. If boot costs more than it saves for a 9-test smoke run, `lab` stays the
  default for smoke and `ephemeral` becomes the default for regression.

## Step 5 — Documentation and invariants

- `docs/tests.md`: both targets, what each is for, and the measured numbers.
- `CLAUDE.md`: the invariants worth protecting — images by explicit tag, no dump restore, the
  three SQL settings, teardown always with logs, and that both targets stay.
- `.agents`/`.claude` skill mirrors, then `./scripts/validate.sh`.
- **Verify:** harness green; a reader who has never seen this can tell which target a red run
  used from its log alone.

## Where this stands, and what is left — 2026-09-22, end of day

The goal moved once more and is now a number: **80% of the suite passing on the lab and on
the ephemeral stack — locally first, then in CI.** Parity is no longer the open question; the
pass rate is.

### Taken

**`@smoke` gives the same answer on both targets.** Lab 9 passed / 1 failed in 6.0 minutes;
ephemeral 9 passed / 1 failed in 5.3 and 5.4 minutes across two consecutive runs whose
per-test times match within a second. The one failure was the same spec on both, and it is
fixed since.

**The full regression on the ephemeral stack, locally: 380 of 418 — 90.9%.** It was 230 of 418
that morning, with 154 tests never reaching a verdict at all. Two hours and eighteen minutes at
four workers.

**The lab is serviceable again.** The reset service went through `:3` (the `/normalize` route
it had been missing, which was killing every lab run at its first step), `:4` (clearing the
channel rows an inbox leaves behind) and `:5` (`/drop`, with a service account scoped to two
deployments and one config map). A credential check now runs before the suite: one attempt
instead of the five that lock the account and take every `api_access_token` call down with it.

Causes found and closed, each of which had been read as flakiness: the Dialer with no
`ENGINE_URL` (the whole campaigns class), a proxy certificate neither the Engine nor BotFlow
trusted (every outgoing bot message marked `failed`), `enableAutomaticAgentAssignment` off in
the Engine's own seeds, two toasts racing for `.nth(0)`, a fixed 10-second sleep against a
20-second wrapup timeout, a click by list position after the list had changed length,
`removeInbox` not skipping soft-deleted rows, a temp-mail provider refusing undici's TLS
fingerprint, and an email inbox whose address *and* name could each be spent exactly once per
database.

### 1. Close the triangle

The lab's own full-regression number is running. After it: **the full `@e2e` on the ephemeral
stack in CI**, which has never happened — local success says little about a runner.
**Closes when:** all three numbers are written down side by side.

### 2. The remaining failures, by class

Nineteen at the last local measurement, and the largest group is already broken open.

| count | class | state |
| --- | --- | --- |
| 7 | `@email` | address and name now unique; QANT-02/03/05 pass, QANT-04 fails on its own counter |
| 3 | `QANT-21`, `QANT-135`, `QANT-136` | the mailbox is created and no mail arrives — the stand sends none |
| 2 | web widget counters | same family as the ten already fixed |
| 7 | `QANT-105`, `130`, `117`, `06`, `74`, `85` | unattributed; these need the pages driven by hand |

**Closes when:** each class is either fixed or written down as a decision, and the pass rate is
above 80% on both targets.

### 3. Two ceilings we are already against

The job around the suite is a literal `timeout-minutes: 150` — GitHub Actions expressions have
no arithmetic, so it cannot follow `suite_timeout_minutes`, and a full run takes 2.3 h at four
workers. And four workers is the ceiling itself: the flow set defines four channel slots.
Running the full regression in CI regularly means raising one of the two, deliberately.

### 4. `/drop` has never been fired

Built, deployed, RBAC verified from inside the pod — and never once run, because it destroys a
shared stand for several minutes. It needs a green light and a moment when QA is not inside.

### 5. Merge

nova.ci `e2e-dev` → `main`, then the temporary bindings in `novatalks.tests` come out and that
branch follows. Still deliberately last: the bindings point at `e2e-dev` and break the moment
it is gone.
