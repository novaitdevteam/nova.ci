# E2E against an ephemeral stack: Spec

**Status:** proposed — plan at [`../plans/2026-09-18-e2e-ephemeral-stack.md`](../plans/2026-09-18-e2e-ephemeral-stack.md)
**Date:** 2026-09-18

## Problem

The Playwright suite runs against one long-lived stand in k3s (`dev-e2e-test`). Everything
built this week works, and the stand is still a single point of failure and a queue:

- **One stand, one run.** The `concurrency` group serializes every run against it, so a
  regression (1.2 h) blocks the next smoke run entirely.
- **State survives runs.** Two regression runs left 977 users, 423 inboxes and 391 teams;
  the suite reads those lists in its own assertions, so the stand degrades as it is used.
  The API cannot clear the residue (no delete endpoint for a conversation; inbox delete is
  soft and freezes the chatbot-setting/team/wrap-up chain), which is why a SQL reset
  service had to be built at all.
- **Nobody can reproduce a red run.** The stand moves under you: another run, a manual
  experiment, a chart change. A failure is not a thing you can re-run twice and compare.
- **It is maintained by hand.** Its `values.yaml` is gitignored, so the licence date,
  locale, agent limit and resource overrides exist only on one laptop.

An ephemeral stack — the whole product started on the runner for the duration of one run —
removes all four. It does not replace the stand: some work genuinely wants a long-lived
environment a human can open.

## What this is not

Not a migration. **Both targets stay**, selected per run, the same shape
`ci-dast-pentest.yaml` already uses for `target: ephemeral | live`:

| `target` | What runs | Who uses it |
| --- | --- | --- |
| `lab` (default) | today's behaviour: the suite against `dev-e2e-test` | manual runs, investigating a failure someone can look at |
| `ephemeral` | the stack boots on the runner, the suite runs against it, everything is torn down | routine CI, parallel runs, reproducing a failure |

## Decisions

| # | Decision | Why, and what it rules out |
| --- | --- | --- |
| D1 | **A `target` input, not a second workflow** | The suite, the report publishing, the notifier and the slot generation are identical either way; only the address the tests point at differs. A second workflow would be a copy that rots — the same argument that keeps `dast-common.sh` single. |
| D2 | **Compose the stack with plain `docker run` on the runner, reusing `dast-common.sh`** | nova.ci already boots postgres, redis and an application container this way for DAST, with a readiness loop that fails loudly. Reusing it means one bring-up implementation, not two. Rules out k3d/kind: a cluster inside the runner would add an image-load step and a networking layer for no gain. |
| D3 | **The form carries tags, not image references**: `engine_tag`, `ui_tag`, `botflow_tag`, with the registry and repository fixed per component in the workflow | Two reasons. A full reference in a form field lets anyone who can dispatch a run make the runner pull an arbitrary container from an arbitrary registry; fixing the left side means the field can only choose a tag inside our own three repositories. And it is what the field is actually for — the operator thinks in build tags, which is what the build workflow publishes and what the notifier reports. Composed as `ghcr.io/novaitdevteam/novatalks.core:<engine_tag>`, `…/novatalks.ui:<ui_tag>`, `…/nova.botflow:<botflow_tag>`. No "latest" lookup, for the reason `ci-dast-pentest.yaml` already documents: the registry's tag list is not date-ordered, so "most recent" can silently test a stale image and report the run as current. Defaults are the tags the stand ran on 2026-09-18 — `2026_R3_NC2-2778_engine_f64f9736`, `2026_R3_development_20fdf74f`, `2026_R3_master_f9126a11` — pinned rather than floating, because a moving default makes a red run indistinguishable from an image change. Passing tags per run is also the point of the whole target: a release candidate, a fix branch's build and the tag the stand runs are one form field apart, which the lab cannot do at all. |
| D4 | **The engine seeds the database itself; no dump is restored** | Proven on 2026-09-18: a fresh database gives 291 migrations, 12 macros, 6 roles, the two seeded inboxes and the AgentBot. A dump would re-introduce exactly the drift (`SeedMeta` already at 7010) that hid missing seeds for months. |
| D5 | **The three stand settings the seeds do not make are applied by the bring-up, in SQL** | `active_until` (an expired trial blocks login behind a promo banner), `locale = en` (the suite asserts English strings), `limits.users = 100` (1 paid agent means the second test cannot create an agent). Each has already cost a red suite; they belong next to the bring-up, not in a runbook. |
| D6 | **The AgentBot token is inserted by the bring-up, matching BotFlow's env** | The seeds create the bot but no token; BotFlow presents `NOVATALKS_BOTAGENT_TOKEN` on every call and the engine answers 401 a minute forever without the row. Same SQL `seed-e2e-lab.sh` runs today. |
| D7 | **BotFlow's flows are built, not exported from the stand**: the canonical `BotAgent_Sys_ChatBot` from `novatalks.botflow.flows` plus N generated slots | An export is a snapshot of whatever the stand happened to hold. Building from the canonical flow and the slot template makes the ephemeral stack reproducible and gives the slot generator one code path for both targets. This is also the honest version of the merge that was reverted on 2026-09-17: the reference flow replaced the QA chatbot logic the tests depend on, so the gap between the two must be closed deliberately, not by overwriting. |
| D8 | **`FILE_DRIVER=local`, no object storage** | The ephemeral stack has no R2 bucket and needs none: the file assertions check upload and retrieval through the app, which the local driver serves. Rules out running MinIO for parity nobody asserts. |
| D9 | **No NATS, campaigns stay off** | Enabling campaigns makes the engine await a NATS connection at boot (`main.ts`), and the module is out of scope for the suite (its tests are already tagged and excluded). Adding NATS to satisfy a disabled module is cost without a reader. |
| D10 | **The tests reach the stack on `localhost` ports; the containers reach each other by container name** | `ENV_URL=http://localhost:8080`, `BOTFLOW_URL=http://localhost:1880/redbot`. The engine's own webhook to BotFlow must use the container name, because it is issued from inside the Docker network — the same distinction that made 451 webhook failures on the lab when a fixture named a dead service. |
| D11 | **`e2e-medium` runner for `target: ephemeral`** | Measured on the stand: engine 1 CPU / 2 GB, postgres 500m / 2 GB, botflow 1 / 1.5 GB, ui 500m / 256 MB, redis 100m / 512 MB — about 3 CPU and 6.3 GB before a single browser starts. Four Chromium workers add roughly 2 GB. A 4-vCPU / 8 GB runner would be at its limit before the suite begins; the 8-vCPU size is the first that is not. Since 2026-09-18 these sizes live in the E2E pool of their own (`e2e-small`/`e2e-medium`), so an ephemeral run competes with neither product builds nor the scan pool. |
| D12 | **`concurrency` keys on the target, not on one global group** | Ephemeral runs share nothing, so they must not queue behind each other; lab runs must. `group: e2e-${{ inputs.env_url }}` already does this by accident — with `target: ephemeral` the key becomes the run id, so the serialization disappears exactly where it is pointless. |
| D13 | **Teardown is unconditional and logs are captured on failure** | `docker logs` of every container into the run artifact when the suite fails: a stack nobody can inspect afterwards is worse than no stack. The same reason `dast-api/scan.sh` prints container logs on a loud skip. |
| D14 | **`reset_stand` has no meaning for `target: ephemeral`, and the workflow says so** | The database is new. Silently ignoring an input the caller set is how a run ends up not doing what its form said; the step refuses the combination rather than skipping quietly. |

## Architecture

```
runner (e2e-medium, 8 vCPU / 16 GB)
├── docker network e2e-<run id>
│   ├── postgres:17.9-trixie      ← engine seeds it on first boot
│   ├── redis:8                   ← engine queues + Node-RED store
│   ├── engine   (novatalks.core) :3000 → published on localhost:3000
│   ├── ui       (novatalks.ui)   :8000 → published on localhost:8080   ENV_URL
│   └── botflow  (nova.botflow)   :1880 → published on localhost:1880   BOTFLOW_URL
│                                          flows = sys chatbot + N slots
└── Playwright, N workers ── HTTP ──> localhost
```

Bring-up order, each step gated on the previous one being ready rather than on a sleep:
postgres → redis → engine (migrations and seeds run at boot; wait for `/readyz`) →
SQL for the three stand settings and the AgentBot token → botflow (wait for `/redbot/`) →
deploy flows → wait for every channel route → ui → run.

## Open questions, to answer with measurements during implementation

| Question | Why it matters | How to answer |
| --- | --- | --- |
| How does the UI image take its configuration? The lab passes 21 `VITE_APP_*` values, and Vite normally bakes those at build time | If they are build-time only, the ephemeral UI needs a different way to point at the engine | Inspect the image's entrypoint; check whether it templates a JS file at start |
| Which of the engine's 155 config keys are actually required to boot | The DAST bring-up already runs the engine with far fewer | Start from the DAST set, add only what the container demands, and record each addition with the error that forced it |
| Does the canonical `BotAgent_Sys_ChatBot` flow transfer a conversation to a team the way the QA flow set does | The reverted merge on 2026-09-17 proved it does not, out of the box | Boot both, send one message, compare the conversation's `team`/`assignee` |
| Boot time end to end | Decides whether ephemeral is viable for a 9-test smoke run or only for regressions | Measure; target under 3 minutes |

## Risks

- **Boot time is paid per run.** If it lands near 5 minutes it doubles a smoke run's wall
  time. Mitigation: pre-pulled images on the reused runner, and `lab` stays the default for
  quick manual runs.
- **The stack drifts from the deployed one.** Nothing keeps the ephemeral env in step with
  the chart. Mitigation: the image tags are inputs, and the three SQL settings are the only
  deviations — anything else the tests need must be a product default or a test change.
- **BotFlow flow parity.** The suite depends on QA flow behaviour that the canonical flow
  may not have. This is the largest unknown and D7 is deliberate about it.
- **Mail.** `QANT-21` reads a real IMAP mailbox. An ephemeral stack cannot make that
  hermetic; it stays an external dependency until someone runs a local mail server, which
  is out of scope here.

## Out of scope

Replacing the lab; campaigns and NATS; object storage parity; making the mail path
hermetic; running more than four workers (the shared-account cleanup races are a test-side
problem and the ephemeral stack does not fix them).
