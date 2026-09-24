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

Closed on 2026-09-23: see below.

### 2026-09-23 — what the day closed, and what it turned into decisions

`/drop` has fired, repeatedly, and item 4 is closed: two minutes, both databases recreated,
the engine and the dialer restarted and re-told each other's tokens. Every lab run since has
started from it.

A teammate's full lab run (6 workers, prune) ended 311 passed, 40 flaky, 16 failed. Of the
sixteen, eleven were fixed today in the suite or the workflow; the rest are decisions below.
A targeted lab run of every group touched (1 worker, after a drop) then came back 33 of 34 with
nothing flaky, and the one failure is the mailbox finding below.

Fixed, each read as flakiness until the cause was found:

- the workflow never passed Mailgun's key, so eight email specs failed at their first step on
  every CI run;
- two team fixtures rang an alert for 20 s against a counter cached for 30 s;
- `stack.sh` handed the engine its S3 key under names it does not read, so every upload on the
  ephemeral target failed;
- QANT-130 read a row before it rendered, and clicked shut a section it meant to open;
- QANT-117 took "no Next button" for "more pages";
- the onboarding modal's wait depended on an external site;
- a settings click straight after sign-in was sometimes swallowed;
- the email counter specs assumed both letters land in one mailbox poll, in send order.

The full lab regression that evening, after a drop, at four workers (run 35889000226), in 49.9 minutes:

| run | passed | flaky | failed | did not run |
| --- | --- | --- | --- | --- |
| teammate, 6 workers, prune (35863839352) | 311 | 40 | 16 | 41 |
| today's fixes, 4 workers, drop (35889000226) | 352 | 23 | 7 | 26 |

Of the seven failures, three are the lab's missing SMTP password (QANT-21/135/136), one is
PrivateBin (QANT-85), one is the mailbox (QANT-02), and two are the shared admin signed out
mid-test (QANT-130/133 — their screenshots are the login page). Nearly everything that needed
a second retry sits in the three Account Settings serial groups (QANT-130/133/134), which is the
same shared-admin sign-out; only QANT-17, 18 and 25 needed it outside them.

**A correction.** The onboarding-modal change was committed as the fix for five 61 s timeouts,
on the reading that the external onboarding site was slow. It was not the cause: in this run
three specs (QANT-25, 34, 85) still stopped there, and their screenshots show the login form
filled in and never submitted — the modal never appeared because the sign-in did not complete.
The change stays (it removes a real dependency on an external site) but the cause is open. The
config records a trace only on the first retry, so no failing first attempt has one; finding it
needs a run with `--trace retain-on-failure`.

**The first full `@e2e` on the ephemeral target in CI** (run 35905206948, four workers, 42.4
minutes) — the triangle's missing corner:

| run | passed | flaky | failed | did not run |
| --- | --- | --- | --- | --- |
| lab, drop, 4 workers (35889000226) | 352 | 23 | 7 | 26 |
| ephemeral, 4 workers (35905206948) | 378 | 19 | 3 | 8 |

It ran with the stack's own mail server (GreenMail): no letter left the runner, and the whole
email class passed. Three causes came out of reading both runs, each looking like flakiness:

- **QANT-21 deleted every agent on the account** from the parallel project, before and after each
  attempt. Other workers' fresh agents vanished between creation and sign-in: POST 200, sign-in
  401, DELETE 404. This is the "login form filled and never submitted" class from the lab run;
  the timings line up with QANT-21's three attempts. It now deletes only its own.
- **Specs that empty a shared collection** (every canned response, every label) ran side by side,
  and so did the account-settings specs that change the account everybody runs in. They now run
  in `workers: 1` projects, alongside everything else. The email specs moved into one too, which
  retires the 170 s lock wait. `fullyParallel: false`, which the old "serial" projects relied on,
  never serialized files — only the tests inside one.
- **CI's `--grep @e2e` runs every chromium test**, 27 of them untagged, because it selects the
  write-first project and Playwright runs a selected project's dependencies in full. The new
  projects are write-first dependencies for that reason, so the selection stays 418 tests.

**2026-09-24 — the shared admin, closed on the ephemeral target.** The stack now seeds seven
extra admins and the suite's default sign-in gives each worker its own; the lab is unchanged
until it seeds a pool of its own.

| ephemeral run | passed | flaky | failed | minutes |
| --- | --- | --- | --- | --- |
| 35905206948 (first) | 378 | 19 | 3 | 42.4 |
| 35910791418 (+ QANT-21, serial groups) | 388 | 6 | 4 | 40.0 |
| 35975580682 (+ admin pool, PrivateBin) | 394 | 5 | 1 | 37.4 |

399 of the 400 tests that ran passed in the end, 394 of them first time. What was left after that:
QANT-74, the admin twin of QANT-45, never got QANT-45's wait for after-call work; and QANT-117,
which fills the account to 100 inboxes, ran beside the inbox CRUD specs that look for their own
row on the table's first page. Both fixed the same day (an `inbox-serial` project).

Then three green full runs in a row — CI conclusion `success`, no failure, every flaky test
passing on its first retry except QANT-75 once (on retry 2, fixed by the attributes group):

| ephemeral run | passed | flaky | failed | minutes |
| --- | --- | --- | --- | --- |
| 35980836422 (+ QANT-74, inbox group) | 405 | 3 | 0 | 36.0 |
| 35986151868 (+ three flake fixes, postgres TCP readiness) | 403 | 5 | 0 | 40.3 |
| 35991556020 (+ attributes group) | 404 | 4 | 0 | 39.5 |

What still flakes is QANT-117, which needs a fixed number of inboxes while nearly every other
spec creates one, and a handful of single retries that did not repeat between runs.

**The lab with the admin pool** (run 35996985089, drop, 4 workers, 43.0 minutes): 387 passed,
9 flaky, 4 failed — against 352 / 23 / 7 the evening before. The four failures are exactly the
two lab decisions below: QANT-21, 135 and 136 get no system mail (no SMTP password), QANT-85
no referral code (no PrivateBin). Four of the nine flaky are the email specs waiting on ukr.net.
Every flaky test passed on its first retry.

**The lab, green** (run 36006157477, drop, 4 workers, 39.8 minutes): 403 passed, 5 flaky, 0 failed
— the first full lab run with no failure. PrivateBin runs next to the lab as release `privatebin`
in namespace `privatebin` (production's chart, filesystem storage instead of R2), and the lab has
its own GreenMail, reached by the suite through stand-reset's `/mail` routes; QA's ukr.net mailbox
is no longer touched. The lab's values (`novatalks.charts/novatalks_v5/examples/dev-e2e-tests`) are
gitignored in that repository, so the mail change lives only in the working copy it was applied
from and in release revision 17.

One correction: every `WORKERS=n local.sh test` before this ran on one worker, because the tests
repository's `.env` sets `WORKERS` and overrode the command line. Fixed in `local.sh`.

Decisions, each needing a word from the owner rather than more code:

| decision | why it cannot be coded around |
| --- | --- |
| ~~one admin identity per worker, on the lab~~ | Done 2026-09-24: the workflow seeds the pool, stand-reset :12 types it. |
| ~~a mail server of the lab's own~~ | Done 2026-09-24. |
| ~~the lab's system SMTP password~~ | Done 2026-09-24: the system mailer points at the lab's GreenMail. |
| ~~PrivateBin on the lab~~ | Done 2026-09-24. |

**2026-09-24 evening — the flakes, by cause.** Four runs, both targets, 4 workers each:

| run | target | passed | flaky | failed | minutes | retry #2 |
| --- | --- | --- | --- | --- | --- | --- |
| 36036607588 | ephemeral | 401 | 7 | 0 | 53.0 | 0 |
| 36036612815 | lab | 406 | 2 | 0 | 37.1 | 0 |
| 36046590432 | ephemeral | 405 | 3 | 0 | 50.4 | 0 |
| 36046595792 | lab | 404 | 4 | 0 | 38.6 | 0 |
| 36055501617 | lab (lease) | 403 | 5 | 0 | 40.1 | 0 |
| 36057459698 | ephemeral (dialer tag named) | 403 | 5 | 0 | 42.0 | 1 (QANT-130) |
| 36062979251 | ephemeral | 406 | 2 | 0 | 36.7 | 0 |
| 36062984485 | lab | 403 | 5 | 0 | 39.5 | 0 |

The last two are the first **green checks** on both targets: CI conclusion `success`, no failed test, no second retry. The artifact quota was still full; the upload now warns instead of failing the job.

Until 36057459698 no test needed a second retry on either target; QANT-130's submenu test then did, and was fixed the same evening (the expand decided before the tree had rendered). The last two runs still ended red: the report
upload hit the organisation's artifact quota (6.3 GB of three days of E2E reports, a ~20 MB trace
per retried test). The old reports were deleted and the report is now kept one day.

What the fixes were, all in `novatalks.tests`:

- **A cleanup that deleted another project's inbox.** `removeEmailInboxes` removed every email
  inbox in the account, and `email-serial` runs beside `inbox-serial`: QANT-88's Microsoft inbox
  lived five seconds on the lab and went the second QANT-56 finished. It now removes only inboxes
  that read the shared mailbox.
- **Two races in the custom-attribute row** (QANT-26–29, 32–35, 38, 39). A date row shows the typed
  value before the engine stores it, while its copy button copies the stored one — QANT-29 pasted
  QANT-28's link; and a new row can miss its focus event and stay in view mode with its input
  hidden. `ui/app/actions/attributeRow.ts` waits for the POST and opens the row itself.
- **An accordion that was toggled, not opened.** Conversation Actions keeps its open state in the
  user's server-side `ui_settings`, so a pool admin carried it between specs and a second click
  closed it (QANT-55, QANT-95). The button now only opens.
- **QANT-21**: two of faker's colour names contain a space, which made the webhook URL invalid.

Still flaking, each once per run or less: QANT-54 (a deleted contact attribute comes back when the
next one is added) and QANT-03/63/73 (the assignee still shown after Resolved) are a **product
bug, confirmed in `novatalks.ui`'s code and left unmasked**: every conversation event
(`conversation.status_changed`, `substatus_changed`, `assignee.changed`) is spread over the stored
conversation with no ordering check (`src/store/conversations/mutations.js`, `UPDATE_CONVERSATION`),
so whichever event arrives last wins even when its snapshot is older, and the same action rewrites
the contact from the event's `meta.sender` (`actions.js`, `updateConversation`), which is how a
deleted attribute returns. It needs an `updated_at` (or sequence) comparison in the UI, or snapshots
built after commit in the engine. A second UI bug, found by the accept check: QANT-52's accept went
to `/api/v1/accounts/null/...` and answered `400`. After a reload `Dashboard.vue`'s
`initializeAccount()` awaits `accounts/get` before `setCurrentAccountId`, so for that long the
sidebar builds its links with a `null` account, a click in that window lands on
`/app/accounts/null/...`, and `ApiClient` takes the account from the path. Setting the id from the
path before the fetch (it is already known) closes it; the email alert specs (QANT-56/58/59) where the chatbot
answered but no transfer to the team followed — the lab's engine logs had rotated before they
could be read; QANT-52/46 (status still `Alerting`), QANT-84/96 (a delete button not found),
QANT-117, QANT-130.

### 5. Merge — on an explicit say-so, never on a green number

nova.ci `e2e-dev` → `main`, then the temporary bindings in `novatalks.tests` come out and that
branch follows. Still deliberately last: the bindings point at `e2e-dev` and break the moment
it is gone.

**This one waits for the word, and nothing else releases it.** Not items 1-4 closing, not a
pass rate crossing 80%, not a clean run on either target. Those are what make the merge
*possible*; they do not make it *due*. Anyone picking this plan up: leave it alone until asked.
