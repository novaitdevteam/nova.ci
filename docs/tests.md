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

[`ci-e2e-tests-manual.yaml`](../.github/workflows/ci-e2e-tests-manual.yaml) runs the Playwright suite from `novatalks.tests` against a running stand — today the e2e lab at `novatalks-e2e-tests.k3s.dev.novait.com.ua` — then publishes the HTML report to R2 and notifies.

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
| `report_base_url` | no link in the notification; otherwise the public base of the report bucket |

The two URLs are **inputs, not secrets**: they are public, and keeping them in the form is what lets the same workflow point at another stand. Only the four credentials and the API token are secrets, and they are named `E2E_*` rather than after any one stand.

One spec (`QANT-21`) waits for an invitation mail, so the mailbox it reads over IMAP is passed too (`E2E_IMAP_*`, `E2E_TEST_EMAIL_ADDRESS`) — a real account's password, hence secrets rather than inputs.

Measured on the e2e lab (`small` = 4 vCPU / 8 GB, `medium` = 8 vCPU):

| Suite | Workers | VM | Wall time | Load (5 min) | Result |
| --- | --- | --- | --- | --- | --- |
| `@smoke` (9 tests) | 4 | small | 7.4 min | 0.9 | 5 passed, 3 flaky, 1 failed |
| `@smoke` | 6 | small | 6.1 min | 1.3 | 4 passed, 2 flaky, 3 failed |
| `@smoke` | 8 | small | 5.9 min | 2.0 | 1 passed, 4 flaky, 4 failed |
| `@e2e` (417 tests) | 4 | small | 1.2 h | 5.4 | 343 passed, 14 flaky, 28 failed |
| `@e2e` | 4 | medium | 1.2 h | 2.7 | 326 passed, 25 flaky, 31 failed |

Two conclusions, both measured rather than preferred. **A bigger VM buys nothing**: doubling the cores halved the load and moved the regression's wall time by zero, because that time is spent waiting on the application and on fixed timeouts (30 s per click, 60 s per `expect`, 360 s per test), not on CPU. And **more workers cost stability faster than they buy time**: 4 → 8 workers on the smoke suite saved 1.5 minutes and turned five passing tests into one, because the suite shares one account and its `afterEach` cleanups delete entities belonging to whichever worker is running alongside. Four workers on `small` is the working setting until that isolation is fixed; the per-worker channel slots, generated on demand against the stand, are the other ceiling.

The run needs seven environment variables for the stand itself — the suite derives `CLIENT_URL` and `CLIENT_URL_API` from `ENV_URL` itself. With `USE_DB` unset it touches no database, so the workflow carries no kubeconfig, no port-forward and no database credentials. Three specs that do need SQL are tagged `@db` and excluded from the default project.

The workflow used to restore the lab database from an R2 dump, reload Redis and restart the engine before running. Those steps were removed on 2026-09-17: they reached the cluster from an in-cluster runner, that runner track is retired, and Hetzner runners have no route into k3s. Seeding the stand is now the stand's own business. Two rules survive from that era: never `FLUSHALL` the stand's Redis (DB 15 holds `nr:flows`, the chatbot logic, which no Postgres dump contains), and runs against one stand stay serialized — the `concurrency` group keys on `env_url`, because concurrent runs create and delete each other's entities.

The notification reports the tests' own result, the stand, the branch and commit that ran, the tags and who dispatched it.

## Reading failures

- **`unit-test` red** — advisory. It does not block the build, but the PR check fails and it is reported in the notifier message.
- **`integration-tests` red** — a real integration failure (no longer hidden). Investigate via the `integration-test-report` artifact on the run.
- **Lint red** — advisory. It does not block the build, but it is reported in the notifier message.

---

[← SAST and DAST](sast-dast.md) · [Docs index](README.md) · [Secret detection →](secret-detection.md)
