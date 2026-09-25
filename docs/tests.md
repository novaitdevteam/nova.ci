# Tests

<p align="center">
  <img src="../assets/readme/tests.svg" width="100%" alt="the advisory lint and unit-test gate in the build workflow, and the unit, integration and both modes of the test workflow" />
</p>

## Unit tests (build gate)

The `unit-test` job runs right after `linter`, on the same runner, on both PR and non-PR events (sequential so a single build does not occupy two runners). It runs even when lint fails (`if: !cancelled()`), and its result is advisory — it does not block `build-image`. It is repo-aware via a "Resolve test plan" step: `novatalks.core` runs `npm run test:unit` (jest `--selectProjects unit`, parallel via jest workers), and `novatalks.flowrunner` runs its own `npm test` (jest over `src/**/*.spec.ts`) after `npm ci` **and** `npx prisma generate` — its specs import `PrismaService`, and `@prisma/client` throws on import until the client is generated; generate itself needs a stub `DATABASE_URL`, because `prisma.config.ts` refuses to load without one and generate never connects with it. All other standard build repositories resolve to a no-op success, so they stay backward compatible. To enable a new repository, add a case in that step.

A no-op success is reported to the notifier as `⏭️ n/a (no unit tests configured)`, **not** `✅` — the "End Unit Step" step checks whether `unit_test_command` was resolved, so a repository that ran zero tests is never shown as having passing tests. A no-op run still reports `success` as the job result.

There is no `continue-on-error`.

## Test workflow modes

[`…-run-test.yaml`](../.github/workflows/ci-build-ntk-on-push-tags-run-test.yaml) accepts `test_mode`:

| `test_mode` | What runs | Trigger tag substring |
| --- | --- | --- |
| `unit` | unit tests only, no DB or Redis services | `unit-test` |
| `integration` (default) | integration tests with postgres + redis:8 services | `int-test` |
| `both` | unit tests, then integration tests | `full-test` |

The three substrings do not collide. In `both` mode the suites run sequentially — `integration-tests` has `needs: [unit-tests]` with a `!cancelled()` condition, so integration still runs when `unit-tests` was skipped (`integration` mode) or failed (`both` mode; the suites report independently), and a `full-test` run needs only one runner.

The workflow also has a `workflow_dispatch` trigger with a `test_mode` choice input, for manual runs inside `nova.ci` without pushing a tag.

## Integration tests

Integration tests run `npm run test:integration` (which already includes `--runInBand --forceExit --silent --verbose`) against redis:8 services shared across all steps. There is no `continue-on-error`; failures fail the job (they used to be masked). npm dependencies are cached via setup-node `cache: npm`.

The Postgres service image is repository-aware:

- `novatalks.core` → official `postgres:17.9-trixie` (PG 17.9 on Debian trixie), matching the production major version
- all other repositories (e.g. `novatalks.ui`) → `postgres:16`

The `POSTGRES_*` env vars, `pg_isready` health check and `CREATE EXTENSION pgcrypto` step are identical everywhere.

File storage is repository-aware too. For `novatalks.core` only, a `Configure S3 (Cloudflare R2) file storage` step writes `FILE_DRIVER=s3` and the `AWS_S3_*` settings to `$GITHUB_ENV` before the run, from the repository secrets `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET` (region `auto`, path-style on). The step is gated on `github.event.repository.name == 'novatalks.core'`, so other repositories keep their default `FILE_DRIVER`. Secrets reach the reusable workflow through the switcher's `secrets: inherit`.

**Sharding** (jest `--shard` + matrix) is intentionally not enabled. Integration tests share database state and run with `--runInBand`; each shard would need its own Postgres and Redis services plus `--shard=i/N`. Unit tests already parallelize via jest workers, and the integration bottleneck is DB I/O, not CPU.

## End-to-end tests (novatalks.tests)

[`ci-e2e-tests-manual.yaml`](../.github/workflows/ci-e2e-tests-manual.yaml) runs the Playwright suite from `novatalks.tests` against a running stand, then publishes the HTML report to R2 and notifies. The report travels between the two jobs as a run artifact kept one day; when it cannot be uploaded — the artifact quota is the organisation's, shared with every product build — the run keeps the suite's own result, warns that it has no report, and the notification says so instead of linking one.

**Two targets, chosen per run by the `target` input.** Both stay; neither replaces the other.
The point of having two is that the same build gives the same result on either, so each starts
from a **defined** account state rather than whatever the last run left: a five-year trial,
`locale = 'en'`, a hundred-agent limit, and automatic agent assignment on. The ephemeral target writes them at boot
(`e2e-stack/stack.sh`); the lab gets them from `POST /normalize` on its own reset service,
called on every lab run. Keep the two lists identical — they answer the same question, and two
copies that drift apart put the targets back out of step silently. That is not hypothetical:
on 2026-09-21 the lab sat on `locale = 'pl'` after an interrupted run and every smoke spec
asserting English text failed there, while the ephemeral stack passed for no better reason
than that it rewrites the row each time.

The fourth setting, `limits.enableAutomaticAgentAssignment`, is the one the engine's own seeds
leave `false`, and with it off a conversation handed to a team only ever joins the queue —
nothing a single-agent run produces drains it. The first message of a spec still rings, because
the chatbot's transfer forces an assignment, so the run looks healthy right up to the second
one, which sits `open/inqueue` with the agent `online/Idle` beside it.

| | `lab` (the default) | `ephemeral` |
| --- | --- | --- |
| What it is | the shared stand at `novatalks-e2e-tests.k3s.dev.novait.com.ua` | the whole product started on the runner for this run, then destroyed |
| Comes from | whatever is deployed there | the release builds the lab runs, unless the form names another tag for an image; a chart version |
| Runs at a time | one — a lease on the stand's own reset service, behind a `concurrency` group on `env_url` | as many as the pool allows; the group keys on the run id |
| State | survives runs, so `reset_stand` exists | new every time, so `reset_stand` is refused |
| Campaigns | cannot run: the engine awaits NATS at boot and the lab has none | run, because the stack brings its own NATS and dialer |
| Costs | a `drop` when asked for one (121 s, run 36062984485) | 139 s of bring-up (run 36062979251), on an `e2e-medium` runner |

One lab run at a time is held by the stand, not only by the workflow. The `concurrency` group
sees runs of this workflow, in one repository, with the same `env_url` string — another spelling
of the URL, another repository or a run started any other way is invisible to it, and GitHub keeps
only one waiting run per group, cancelling the one before it. So the lab's reset service also
holds a lease: `Take the stand` takes it before anything changes the stand (waiting up to 90
minutes, naming the holder while it waits), `/drop`, `/prune` and `/normalize` answer `409` to a
run that does not hold it, and `Release the stand` gives it back on every exit. A run killed
before it can release frees the stand when the lease runs out, 160 minutes after it was taken.

The ephemeral stack boots the same four release builds the lab runs; they are written once, in
the bring-up step of `ci-e2e-tests-manual.yaml`, and change together with the lab's. The form's
`engine_tag`, `ui_tag`, `botflow_tag` and `dialer_tag` replace one image each, for a build that is
not on the lab yet; left empty they mean the release build. A lab run refuses them rather than
ignoring them, because the lab tests whatever is deployed on it.

What the lease does not see: a suite started any other way that never calls the reset service —
Playwright run from a laptop against the lab, without the reset token. Such a run cannot prune,
normalise or drop the stand, but its specs still create and delete entities, sign the pool admins
in and read the shared mailbox, and nothing stops it. Taking the lease in the suite's
`global-setup` would close that gap; it is not done while no such runs are known to happen.

Use `lab` when a human wants to open the thing afterwards and look. Use `ephemeral` to test a
particular build, to run two suites at once, or to get a failure somebody else can reproduce —
the stand moves under you, and a run there cannot be repeated twice the same way.

The ephemeral stack is [`e2e-stack/stack.sh`](../.github/actions/e2e-stack/stack.sh): postgres,
redis, NATS, the engine, the dialer, BotFlow, the UI and one nginx serving the single origin
`http://localhost:18080`. Its configuration is rendered from the published chart rather than
kept here, its flows are copied from the stand at boot, and it is torn down whatever the suite
did — with every container's log when the suite went red, and on every run a digest of the
engine's mail fetches, warnings and errors, because the email specs flake one poll at a time and
pass on a retry, which used to leave nothing to read. First green run against it:
2026-09-21, `@CI` in 55.8s on a stack that took about a minute to come up.

It is **dispatch only**. Open `novatalks.tests` → Actions → **CI Build Trigger** → **Run workflow**; the caller creates the runner and the switcher forwards the form:

| Input | Empty means |
| --- | --- |
| `tests_ref` | the branch picked in "Use workflow from" |
| `test_tags` | all tests. Otherwise Playwright tags, `@smoke` or `@smoke + @regression` (each ` + ` becomes a `--grep` alternative) |
| `env_url` | required — the stand's base URL |
| `botflow_url` | required — base URL + adminPath, e.g. `…/redbot` |
| `exclude_tags` | skip nothing. Otherwise tags to leave out, `@campaigns`, applied as `--grep-invert` |
| `workers` | two. One Node-RED channel slot per worker; the slots are reconciled against the stand at run start, so a worker count with no slot yet gets one |
| `runner_size` | `small`. `medium`/`large` exist for measuring — see the table below for why routine runs stay on `small` |
| `reset_stand` | `prune` — the run deletes what earlier runs left, through the Engine API, before it starts. `deep` also calls the stand's own SQL reset for the residue the API cannot touch. `off` keeps everything, for investigating a failure |
| `report_base_url` | no link in the notification; otherwise the public base of the report bucket |
| `suite_timeout_minutes` | 120, which leaves room for the slowest legitimate run — the `@e2e` regression takes about 40 minutes at four workers (it took 75 before the flake fixes of 2026-09-24). Lower it for a smoke run |

**A run is bounded twice, and on purpose.** The suite step carries
`suite_timeout_minutes` (120); the job carries a literal 150, because GitHub Actions
expressions have no arithmetic — `${{ inputs.x + 30 }}` does not fail that line, it fails the
whole file to parse. The step is what normally fires: it
fails that step alone, so the report is still uploaded and an ephemeral stack is still torn
down, where a job timeout cancels everything and leaves much less to read. Playwright has its
own `globalTimeout` on CI, set slightly under the step, so the usual outcome is a report that
says where the run stopped.

Without them the default is GitHub's six hours. The E2E pool holds two runners, so one hung
run halves it: run 35583263280 sat in the suite step for 90 minutes and every E2E run queued
behind it. The gap that produced it is worth knowing — `globalSetup` (the Node-RED token, the
prune, the slot reconcile) is covered by no per-test timeout at all, so a request there that
never returns hangs a run with nothing else to stop it.

The two URLs are **inputs, not secrets**: they are public, and keeping them in the form is what lets the same workflow point at another stand. Only the four credentials and the API token are secrets, and they are named `E2E_*` rather than after any one stand.

One spec (`QANT-21`) waits for an invitation mail, so the mailbox it reads over IMAP is passed too (`E2E_IMAP_*`, `E2E_TEST_EMAIL_ADDRESS`) — a real account's password, hence secrets rather than inputs. The email-channel specs (`QANT-02`–`05`, `56`–`59`) send their inbound letter through Mailgun, so its key and domain are passed as well (`E2E_MAILGUN_API_KEY`, `E2E_MAILGUN_DOMAIN`). Without them the client throws `Parameter "key" is required` before anything is sent, and all eight fail at their first step. Those secrets serve the lab only.

**On the ephemeral target no letter leaves the machine.** The stack runs its own mail server
(GreenMail: SMTP and IMAP, any address, any password), points both of the engine's mailers at it,
and hands the suite `E2E_MAIL_HOST` / `E2E_MAIL_SMTP_PORT` / `E2E_MAIL_IMAP_PORT`. With those set
the suite's mail helpers use it instead of Mailgun, the ukr.net mailbox and the temp-mail website:
a customer's letter is appended to the shared inbox the engine polls, and a system letter is read
back from the agent's own mailbox there. The external path had two faults nobody could fix from
the suite: ukr.net answering Mailgun with `421` so letters landed 10-21 minutes late, and a system
mailer with no SMTP password on the lab. The stack also runs PrivateBin, which the engine stores
referral codes in: without it the referral endpoint answered `500` on both targets. Both also run production's GeoIP API: the engine looks up the address of every sign-in with a
one-second timeout, and with no GeoIP to answer, each one waited that second out and logged a
failure. The lab has it on the dev cluster at the address the chart already gives the engine
(`novatalks-system`), the stack on loopback port `18300`.

Measured on the e2e lab (`small` = 4 vCPU / 8 GB, `medium` = 8 vCPU):

| Suite | Workers | VM | Wall time | Load (5 min) | Result |
| --- | --- | --- | --- | --- | --- |
| `@smoke` (9 tests) | 4 | small | 7.4 min | 0.9 | 5 passed, 3 flaky, 1 failed |
| `@smoke` | 6 | small | 6.1 min | 1.3 | 4 passed, 2 flaky, 3 failed |
| `@smoke` | 8 | small | 5.9 min | 2.0 | 1 passed, 4 flaky, 4 failed |
| `@e2e` (417 tests) | 4 | small | 1.2 h | 5.4 | 343 passed, 14 flaky, 28 failed |
| `@e2e` | 4 | medium | 1.2 h | 2.7 | 326 passed, 25 flaky, 31 failed |

**Run the ephemeral stack on your own machine** with
[`e2e-stack/local.sh`](../.github/actions/e2e-stack/local.sh) — `up`, `down`, `env`, `test`. It runs
the same `stack.sh` CI runs, reads the GHCR token and the stand's BotFlow admin out of the two
repositories' own `.env` files without printing either, and prints the variables to export
before `npx playwright test`. `test <grep> [playwright args]` runs the suite in a container on
the stack's network, so `test 'QANT-105-' --retries 0 --trace on` traces a first attempt. With no
real S3 endpoint in the environment, `up` starts a local MinIO for uploads: a placeholder
endpoint boots fine and fails every attachment.

Use it before reaching for a CI run. On 2026-09-21 a laptop found four defects in twenty
minutes that fifteen CI runs had not: `sed -i -E` is GNU-only and had been silently mangling
nothing on a Mac; a container that died on an occupied port went unnoticed because
`docker run -d` had already returned an id; a port guard written that same hour used `ss`,
which does not exist on macOS, and so checked nothing; and both workflows carried a
`FILE_DRIVER=local` fallback for a driver neither the engine nor the dialer has — a branch
that had never been taken because the secrets were always present. A CI round trip costs
minutes plus a runner queue and yields one log; locally you have the containers.

What still needs CI: the runner pool's own behaviour (caps, reuse), a port already taken on
the VM, and the suite under real parallel load.

**Measurements against the ephemeral target**, 2026-09-21, `@smoke` with four workers on
`e2e-medium` (run 35636742304): **5 passed, 4 flaky, 1 failed** out of ten tests, 6.3 minutes
including about a minute of bring-up. The one hard failure is `QANT-21`, which reads a real
IMAP mailbox — an external dependency no ephemeral stack makes hermetic.

An earlier run the same day (35611733629) had 2 failures in 9 tests over 8.5 minutes. The
difference is TLS: the web widget's bundle builds its socket URL as `wss://` and cannot be
told otherwise, so against a plain-http origin it never connected and `QANT-48` timed out on
a conversation it had already created. The tenth test is the campaigns one, which became
runnable the same day. The same tag against the lab (run 35615371703) was **9 failed, 0 passed**, so the
comparison Step 4 of the plan wants cannot be completed yet — not because the ephemeral
target went unmeasured, but because the reference was not in a state to measure against.

**Measurements after the four fixes below**, 2026-09-22, `@smoke` at one worker against a
locally-run ephemeral stack: **9 passed, 1 failed, zero flaky**, 5.4 and 5.3 minutes across two
consecutive runs whose per-test times match within a second. The one failure is still
`QANT-21`. Two runs at four workers on the same build had produced four and five retries.

What those retries were is worth stating precisely, because the standing explanation was only
half right. The shared-account cleanup race described below is real and does account for
retries at four workers. It did **not** account for `QANT-45`, which failed all three attempts
at one worker on a stack nothing else was touching: that was the account setting above, plus a
fixed 10-second sleep in the spec racing a 20-second `wrapup_timeout`. Four workers had been
*hiding* it — another worker's traffic was the event that drained the queue.

Two conclusions, both measured rather than preferred. **A bigger VM buys nothing**: doubling the cores halved the load and moved the regression's wall time by zero, because that time is spent waiting on the application and on fixed timeouts (30 s per click, 60 s per `expect`, 360 s per test), not on CPU. And **more workers cost stability faster than they buy time**: 4 → 8 workers on the smoke suite saved 1.5 minutes and turned five passing tests into one, because the suite shares one account and its `afterEach` cleanups delete entities belonging to whichever worker is running alongside. Four workers on `small` is the working setting until that isolation is fixed; the per-worker channel slots, generated on demand against the stand, are the other ceiling.

**The full regression on both targets, 2026-09-24/25** — `@e2e`, four workers, every run a CI run:

| Run | Target | Passed | Flaky | Failed | Suite | Setup |
| --- | --- | --- | --- | --- | --- | --- |
| 36036607588 | ephemeral | 401 | 7 | 0 | 53.0 min | |
| 36036612815 | lab | 406 | 2 | 0 | 37.1 min | |
| 36046590432 | ephemeral | 405 | 3 | 0 | 50.4 min | |
| 36046595792 | lab | 404 | 4 | 0 | 38.6 min | |
| 36062979251 | ephemeral | 406 | 2 | 0 | 36.8 min | 139 s bring-up |
| 36062984485 | lab | 403 | 5 | 0 | 39.6 min | 121 s `drop` |

The last pair is the first where both concluded `success` with no test needing a second retry.
What it says for choosing a target: the two now cost the same — the ephemeral bring-up and the
lab's `drop` are two minutes each, and the suite runs within three minutes of each other — and
they are equally stable. What still separates them is not time. The lab runs one suite at a time
and keeps its state for somebody to look at afterwards; the ephemeral stack runs as many as the
pool allows, shares nothing, and can boot a build that is not on the lab yet. `lab` stays the
default — the owner's decision on 2026-09-25, taken on these numbers — and `ephemeral` is chosen
on the form when a run needs one of those.

The run needs seven environment variables for the stand itself — the suite derives `CLIENT_URL` and `CLIENT_URL_API` from `ENV_URL` itself. With `USE_DB` unset it touches no database, so the workflow carries no kubeconfig, no port-forward and no database credentials. Three specs that do need SQL are tagged `@db` and excluded from the default project.

`deep` exists because the API-level prune has a floor it cannot go below: the Engine API has no delete endpoint for a conversation at all, so a contact that owns one is permanently undeletable through it, and an inbox delete is a *soft* delete whose row still satisfies every reference check — which freezes the chain inbox → chatbot setting → team → wrap-up code. Two regression runs left 363 contacts, 363 conversations, 412 wrap-up codes and 81 chatbot settings that no API caller could clear. The stand answers one route for that (`POST /stand-reset/prune` on its own host, bearer token, no parameters — there is nothing to aim), and the workflow calls it with `curl -f`, so a 401 or a 500 fails the job: a reset that quietly did nothing is the failure the step exists to prevent. Its source and manifest live in `novatalks.tests/tools/stand-reset/`, deliberately outside the product chart.

Pruning happens **before** the suite, never after. A cancelled or crashed run never reaches an "after" step, so the leftovers that matter most — the ones from the run that went wrong — would be exactly the ones that survive; and starting from a known state needs no record of what this run created. It is a real cost: two regression runs left 977 users, 423 inboxes and 391 teams on the stand, and the suite reads those lists in its own assertions. The prune keeps the seeded baseline (the account, its three seeded users, the AgentBot and its token, the seeded roles and macros) and goes through the Engine API with the same `E2E_API_TOKEN` the suite uses — CI has no database access and must not grow any.

The workflow used to restore the lab database from an R2 dump, reload Redis and restart the engine before running. Those steps were removed on 2026-09-17: they reached the cluster from an in-cluster runner, that runner track is retired, and Hetzner runners have no route into k3s. Seeding the stand is now the stand's own business. Two rules survive from that era: never `FLUSHALL` the stand's Redis (DB 15 holds `nr:flows`, the chatbot logic, which no Postgres dump contains), and runs against one stand stay serialized — the `concurrency` group keys on `env_url`, because concurrent runs create and delete each other's entities.

The notification reports the tests' own result, the stand, the branch and commit that ran, the tags and who dispatched it.

## Reading failures

- **`unit-test` red** — advisory. It does not block the build, but the PR check fails and it is reported in the notifier message.
- **`integration-tests` red** — a real integration failure (no longer hidden). Investigate via the `integration-test-report` artifact on the run.
- **Lint red** — advisory. It does not block the build, but it is reported in the notifier message.

---

[← SAST and DAST](sast-dast.md) · [Docs index](README.md) · [Secret detection →](secret-detection.md)
