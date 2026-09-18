# E2E against an ephemeral stack: Plan

**Spec:** [`../specs/2026-09-18-e2e-ephemeral-stack.md`](../specs/2026-09-18-e2e-ephemeral-stack.md)
**Status:** not started
**Date:** 2026-09-18

Each step ends in something observable. A step whose verification cannot fail is not done —
it is the guard-that-measures-nothing this repository refuses everywhere else.

## Step 0 — Answer the four open questions first

Nothing below is worth building if the UI cannot be pointed at a different engine, or if the
canonical BotFlow flow cannot transfer a conversation.

- Pull `novatalks.ui`, inspect its entrypoint, and find how the 21 `VITE_APP_*` values reach
  the served bundle. **Verify:** start it alone with an engine URL that is obviously not the
  lab's, load `/`, and read the URL the page actually calls.
- Boot `novatalks.core` with the DAST bring-up's env set. **Verify:** `/readyz` answers 200;
  record every key that had to be added and the error that demanded it.
- Boot BotFlow with the canonical `BotAgent_Sys_ChatBot` from `novatalks.botflow.flows`, send
  one message, and read the conversation back. **Verify:** `team` and `assignee` are set, not
  `null` — this is exactly what the reverted merge failed at on 2026-09-17.
- **Verify overall:** a written note of the four answers, in the spec's open-questions table.

If BotFlow parity fails here, stop and decide: adapt the canonical flow, or carry a QA flow
artifact. Do not proceed by overwriting the stand's flows again.

## Step 1 — `stack.sh`: bring the stack up and tear it down

A single script in `.github/actions/e2e-stack/`, sourcing `dast-common.sh` for the postgres
and redis bring-up rather than repeating it.

- `up`: network, postgres, redis, engine (wait `/readyz`), the three SQL settings and the
  AgentBot token, botflow (wait `/redbot/`), ui (wait `/`).
- `down`: always runs, prints `docker logs` for every container when the suite failed.
- Fails loudly with the container's own log on any wait that expires — never "the image did
  not come up" with no evidence.
- **Verify:** run it on a runner by hand; `/readyz`, `/redbot/` and the UI all answer; then
  `down` leaves no container, no volume and no network behind (`docker ps -a`, `docker volume ls`).

## Step 2 — Flows for an ephemeral BotFlow

- Assemble the flow document: canonical sys chatbot + N slots from the existing
  `slot-template.json`, with the webhook base pointing at the engine's container name.
- Deploy it through the Node-RED admin API, then wait for every `/telegram|viber|messenger/<n>`
  route to answer.
- **Verify:** with `WORKERS=4`, all 12 routes answer; a message posted to `/telegram/1` creates
  a conversation and it reaches a team.

## Step 3 — Wire the target into the workflow

- `target` input (`lab` default, `ephemeral`), plus `engine_image` / `ui_image` /
  `botflow_image`, each defaulting to the tag the stand runs.
- `ephemeral` resolves `ENV_URL` and `BOTFLOW_URL` to the published localhost ports and
  ignores nothing silently: `reset_stand` with `target: ephemeral` fails the step with a
  message, per D14.
- `runner_size` resolves to `medium` for `target: ephemeral` (D11) — one more arm in
  `ci-build-create-runner.sh`, with its scenario in `scripts/test-create-runner.sh` in the
  same change, per the repository's own rule.
- `concurrency` keys on the run id for `ephemeral`, on `env_url` for `lab` (D12).
- **Verify:** `@CI` green on `target: ephemeral`; the same tag still green on `target: lab`;
  two ephemeral runs at once both finish (no queueing).

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

## Sequencing note

Steps 0–2 are independent of the merge of `e2e-dev` → `main`, and can run in parallel with the
test-side isolation work: they touch different repositories. Step 3 must land after that merge,
because the caller's temporary blocks disappear with it.
