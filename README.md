# `nova.ci`

Shared GitHub Actions workflows for NovaTalks repositories.

## Main Entry Point

Connected repositories keep a local `.github/workflows/ci-build-trigger.yaml` workflow. That local workflow handles repository events, prepares or selects a runner, and calls:

[`ci-build-trigger-switcher.yaml`](.github/workflows/ci-build-trigger-switcher.yaml)

The switcher receives the original repository event context and routes execution by:

- repository name
- event name and action
- ref type: branch or tag
- ref name
- commit message

## Connected Repository Contract

Most product repositories use the same local caller workflow:

```yaml
name: CI Build Trigger
on:
  workflow_dispatch:
  push:
  pull_request:
  pull_request_target:
  pull_request_review:
  pull_request_review_comment:
```

That local workflow:

- checks for an available self-hosted runner
- creates a Hetzner runner when needed
- calls `novaitdevteam/nova.ci/.github/workflows/ci-build-trigger-switcher.yaml@main`
- passes `runner_labels` from the runner selection step
- uses `secrets: inherit`

Build routing should stay centralized in [`ci-build-trigger-switcher.yaml`](.github/workflows/ci-build-trigger-switcher.yaml). Do not add repository-specific build dispatch rules to local caller workflows unless a repository intentionally needs a different caller contract.

The local caller may receive PR-related events that the switcher does not route. Only matched switcher jobs perform shared CI work.

## Dispatch Rules

The central switcher currently routes these events:

| Event | Repositories | Condition | Called workflow |
| --- | --- | --- | --- |
| `push` | standard build repositories | branch is `master` or `development` | [`ci-build-ntk-on-push-direct-to-protected-branches.yaml`](.github/workflows/ci-build-ntk-on-push-direct-to-protected-branches.yaml) |
| `push` | standard build repositories | tag ref contains `build`, or starts with `scan` | [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml) |
| `push` | standard build repositories | branch push commit message contains `build` | [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml) |
| `pull_request` | `novatalks.core` | non-draft PR on `opened`, `synchronize`, `reopened`, or `ready_for_review` | [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml) with `build-engine` and `build-reporting` matrix |
| `pull_request` | standard PR build repositories | non-draft PR on `opened`, `synchronize`, `reopened`, or `ready_for_review` | [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml) with `build_target: build` |
| `push` | `novatalks.core` | tag contains `int-test` | [`ci-build-ntk-on-push-tags-run-test.yaml`](.github/workflows/ci-build-ntk-on-push-tags-run-test.yaml) with `test_mode: integration` |
| `push` | `novatalks.core` | tag contains `unit-test` | [`ci-build-ntk-on-push-tags-run-test.yaml`](.github/workflows/ci-build-ntk-on-push-tags-run-test.yaml) with `test_mode: unit` |
| `push` | `novatalks.core` | tag contains `full-test` | [`ci-build-ntk-on-push-tags-run-test.yaml`](.github/workflows/ci-build-ntk-on-push-tags-run-test.yaml) with `test_mode: both` |
| `push` | `nova.docs` | tag contains `build` | [`ci-build-ntk-on-push-tags-gh-deploy.yaml`](.github/workflows/ci-build-ntk-on-push-tags-gh-deploy.yaml) |
| `push` | `novatalks.ui-lite` | tag contains `build-apk` | [`ci-build-ntk-on-push-tags-mob-apk-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-mob-apk-build.yaml) |
| `push` | `novatalks.mobile` | tag contains `build-apk` | [`ci-build-ntk-on-push-tags-mob-apk-build-public.yaml`](.github/workflows/ci-build-ntk-on-push-tags-mob-apk-build-public.yaml) |
| `push` | `novatalks.ui-lite` | tag contains `build-pwa`, `build-spa`, or `build-crm` | [`ci-build-ntk-on-push-tags-mob-pwa-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-mob-pwa-build.yaml) |
| `push` | `novatalks.chatwidget` | tag contains `build` | [`ci-build-ntk-on-push-tags-widget-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-widget-build.yaml) |
| `push` | any repository | branch name contains `build-me-please` | [`ci-build-ntk-on-push-branches.yaml`](.github/workflows/ci-build-ntk-on-push-branches.yaml) |
| `push` | `novatalks.botflow.flows` | tag contains `build` | [`ci-build-ntk-on-push-tags-flows-to-pub.yaml`](.github/workflows/ci-build-ntk-on-push-tags-flows-to-pub.yaml) |
| `push` | `novatalks.tests` | any tag | [`ci-e2e-tests-manual.yaml`](.github/workflows/ci-e2e-tests-manual.yaml) |

Standard build repositories:

- `novatalks.core`
- `novatalks.ui`
- `nova.botflow`
- `nova.chatsconnector.telegram-client-api`
- `novatalks.dialer`
- `nova.chatsconnector.genesys.cloud.premium.wizard.engine`
- `novatalks.geoip-api`
- `nova.chatsconnector.whatsapp-client-api`
- `novatalks.uspacy.connector`

Standard PR build repositories are the same list except `novatalks.core`, because `novatalks.core` has dedicated PR targets.

## Pull Request Builds

Pull request events run lint and unit tests only. The switcher still routes supported non-draft PR events into [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml), but the `build-image`, `trivy-scan`, and notifier jobs are skipped when `github.event_name == 'pull_request'`. The `linter` and `unit-test` jobs both run for opened, synchronized, reopened, or ready-for-review PRs. No Docker image is built or published, and no notification is sent.

Pull request builds do not create Git tags. The switcher passes a synthetic `build_target` into the build workflow so lint targeting still resolves correctly:

For `novatalks.core`, every supported non-draft PR event lints two targets:

- `build-engine`
- `build-reporting`

Unit tests run once for `novatalks.core` PRs: they execute on the `build-engine` leg and are skipped on the `build-reporting` leg to avoid duplicate runs.

For other standard PR build repositories, the switcher passes:

```yaml
build_target: build
```

That makes PR lint follow the same lint strategy used by `build*` tags.

## Build Workflow

[`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml) accepts:

- `runner_labels`: optional runner label override
- `build_target`: optional synthetic build selector used mainly by PR dispatch
- `trivy_severity`: severities counted by the Trivy scan and fail policy (default `CRITICAL,HIGH`)
- `trivy_mode`: scan policy mode, `warn-only` (default) or `fail-on-critical`

When `build_target` is empty, the workflow resolves behavior from `github.ref_name`. When `build_target` is set, it is used for lint and Dockerfile selection.

The `linter` and `unit-test` jobs always run (on both PR and non-PR events). The `build-image`, `trivy-scan`, and notifier jobs are gated on `github.event_name != 'pull_request'`, so pull request events run lint and unit tests only and never build, scan, or publish an image.

`build-image` has `needs: [linter, unit-test]`. Lint is advisory: the build still runs if lint fails. A unit test failure blocks the build. The `build-image` condition is `!cancelled() && github.event_name != 'pull_request' && needs.unit-test.result == 'success'`.

### Lint Behavior

For `novatalks.core`, linting is targeted by build target:

- `build-engine` -> `npx eslint apps/engine libs/common libs/database --ext .ts`
- `build-reporting` -> `npx eslint apps/reporting libs/common libs/database --ext .ts`
- any other target -> `npm run lint`

`novatalks.core` lint also uses `NODE_OPTIONS=--max-old-space-size=4096`.

Other repository-specific lint strategies are defined inside the build workflow. Repositories without a specific strategy use the fallback eslint bootstrap path.

### Dockerfile Selection

Dockerfile selection is based on `build_target` when present, otherwise `github.ref_name`:

- `build-engine` -> `docker/engine.Dockerfile`, image suffix `_engine`
- `build-reporting` -> `docker/reporting.Dockerfile`, image suffix `_reporting`
- `build-restore-historical` -> `docker/restore-historical.Dockerfile`, image suffix `_restore-historical`
- `build-message-source-id` -> `docker/message-source-id.Dockerfile`, image suffix `_migrate-message-source-id`
- default, including `build` -> `docker/server.Dockerfile`, no image suffix

### Image Tags

Images are pushed to Docker Hub and GHCR with this format:

```text
<release>_<short-ref-name><image-suffix>_<short-sha>
```

`short-ref-name` is resolved from:

- `github.head_ref` for pull requests
- `github.ref_name` for branch builds
- `github.event.base_ref` for tag builds

The value is sanitized so characters invalid for Docker tags, such as `/`, are replaced with `-`.

The workflow deletes the source tag only for real tag-triggered builds where `build_target` is empty. PR builds never delete tags.

The mobile PWA/SPA/CRM workflow uses the same suffix placement:

- `build-pwa` -> image suffix `_pwa`
- `build-spa` -> image suffix `_spa`
- `build-crm` -> image suffix `_crm`

Those images are tagged as:

```text
<release>_<short-ref-name><image-suffix>_<short-sha>
```

### Build Cache

The build workflow uses a GHCR registry cache per image variant:

```text
ghcr.io/<owner>/<repo>:buildcache<image-suffix>
```

Cache import is always configured. Cache export is enabled only when the source branch is `master`, `development`, or `main`.

### Container Image Security Scanning (Trivy)

After a successful `build-image`, the `trivy-scan` job scans the exact image that was just built and pushed to GHCR:

```text
ghcr.io/<owner>/<repo>:<release>_<short-ref-name><image-suffix>_<short-sha>
```

Like the rest of the build pipeline, the scan never runs on `pull_request` events; PRs stay lint-only.

**When the scan runs**

The `trivy-scan` job decides whether to scan in its `Resolve scan policy` step:

- Automatically when the build source branch (`SHORT_REF_NAME`) is `main`, `master`, or `development`.
- On demand when the triggering tag ref **starts with** `scan` (for example `scan` or `scan-NC2-1234`). This lets a feature/fix branch be scanned the same way `build` triggers a build.

When neither condition matches (for example a `build` tag on a feature branch), the image is built but the scan is skipped and the job logs the reason. The tag name is only a trigger keyword; the branch, repository, and commit are always derived from the push metadata (`base_ref`, `GITHUB_REPOSITORY`, `GITHUB_SHA`), not from the tag name.

**How to trigger a scan for a specific branch**

Push a tag whose name starts with `scan` onto the commit you want checked. Such a tag both builds the image and scans it. The trigger tag is consumed and deleted like a `build` tag (the persistent report release tag is separate):

```bash
git checkout my-feature-branch
git tag scan-NC2-1234
git push origin scan-NC2-1234
```

**What the scan does**

- Installs Docker, then `docker pull`s the built image (`linux/amd64`).
- Scans with the official [`aquasecurity/trivy-action@v0.36.0`](https://github.com/aquasecurity/trivy-action). The action installs Trivy and manages the vulnerability DB and Java DB internally, so no manual two-step DB download is needed.
- Runs three `trivy image --scanners vuln` passes for the configured severities (default `CRITICAL,HIGH`): one for OS packages (`TRIVY_PKG_TYPES=os`), one for libraries (`TRIVY_PKG_TYPES=library`), and one JSON pass used only to count findings. The OS and library passes reuse the first install via `skip-setup-trivy: true`.
- Assembles a single `.report` file (`trivy-<repo>-<ref><suffix>-<sha>.report`) with an `=== OS Vulnerabilities ===` section and a `=== Node.js Vulnerabilities ===` section, matching the layout produced by the manual scan script.
- Counts CRITICAL and HIGH findings and prints them to the job log and the GitHub Actions job summary.

**Trivy DB cache (5-hour window)**

The Trivy DBs are cached under `${{ github.workspace }}/.cache/trivy` via `actions/cache`, with the action's own cache disabled (`cache: false`). The cache key includes a 5-hour time bucket (`trivy-db-5h-<floor(epoch/18000)>`), so a fresh DB is fetched at least every ~5 hours while runs inside the same window reuse the cached DB.

**Fail / warning policy**

`trivy_mode` controls pipeline behavior on findings:

- `warn-only` (default): the job always succeeds. Any CRITICAL/HIGH findings are surfaced as a `::warning::` and in the job summary, but they do not break the build or release.
- `fail-on-critical`: the job fails when at least one CRITICAL vulnerability is found. HIGH findings still only warn.
- `fail-on-high`: the job fails when at least one CRITICAL **or** HIGH vulnerability is found.

In every mode the image is built and pushed before the scan runs, so a failing scan marks the workflow run red as a signal but does not unpublish the already-built image.

**Where to find the report**

- Release asset: the `.report` is attached to a GitHub prerelease tagged `TRIVY.SCAN_<release>_<ref><suffix>_<sha>` and is downloadable by URL, like the chat widget build:

  ```text
  https://github.com/<owner>/<repo>/releases/download/TRIVY.SCAN_<release>_<ref><suffix>_<sha>/trivy-<repo>-<ref><suffix>-<sha>.report
  ```

- Artifacts: the same `.report` is uploaded as a run-scoped workflow artifact.
- Job summary: severity counts table plus a direct link to the report on the run page.
- Job logs: the `Assemble report` and `Publish scan summary and apply policy` steps.
- Notifications: the Telegram and Google Chat build message includes a Trivy line, color-coded by worst severity — `🔴 CRITICAL found!`, `🟠 HIGH found`, `🟢 clean` (or `❌ FAILED` only under a fail mode, `⏭️ skipped` when no scan ran) — plus the CRITICAL/HIGH counts and the report download link. The job summary shows a matching colored alert banner (`CAUTION` / `WARNING` / `NOTE`). With the default `warn-only` mode the build stays green; the styling is the signal. The notifier waits for `trivy-scan` to finish before sending.

### Docker and Buildx

Docker build jobs call [`install-docker/action.yml`](.github/actions/install-docker/action.yml) before Docker login, Buildx setup, or Docker image builds. The action is idempotent: it exits early when Docker CLI and daemon are already available, otherwise it installs Docker and starts the daemon.

[`ci-build-ntk-on-push-tags-mob-pwa-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-mob-pwa-build.yaml) uses a named Docker context `builder` for Buildx and creates it idempotently:

```bash
docker context inspect builder >/dev/null 2>&1 || docker context create builder
```

This avoids failing reused self-hosted runners where the context already exists.

### Mobile APK Builds

Mobile APK workflows use Node.js `22.22.0` so current Quasar/Icongenie tooling satisfies its Node engine requirement:

- [`ci-build-ntk-on-push-tags-mob-apk-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-mob-apk-build.yaml): internal `novatalks.ui-lite` APK/AAB build
- [`ci-build-ntk-on-push-tags-mob-apk-build-public.yaml`](.github/workflows/ci-build-ntk-on-push-tags-mob-apk-build-public.yaml): public `novatalks.mobile` APK build from `novatalks.ui-lite`

Both APK workflows install `zip` and `unzip` before Gradle setup. `unzip` is required by `gradle/actions/setup-gradle`, and `zip` is used when packaging release artifacts.

The APK build scripts resolve the Android SDK from `ANDROID_SDK_ROOT` or `ANDROID_HOME`, falling back to common self-hosted runner locations. They then:

- export the resolved SDK path back to `ANDROID_HOME` and `ANDROID_SDK_ROOT`
- install required SDK packages with `sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.0"`
- write `src-capacitor/android/local.properties` with `sdk.dir=<resolved-sdk-path>`
- locate `apksigner` under the resolved SDK and use it for APK/AAB signing

### Notifications

Notifier jobs use [`action-cond/action.yml`](.github/actions/action-cond/action.yml) to select success or failure message text.

Telegram notifications are sent with `actions/github-script@v8` and Node.js `fetch` directly to the Telegram Bot API. Workflows that notify Google Chat also use `actions/github-script@v8` and Node.js `fetch` against the configured webhook.

Notifier jobs do not use Docker-based Telegram actions and do not require Docker.

The notifier message includes a `Unit Tests Status:` line (✅ passed / ❌ failed) alongside the existing ESLinter status line, reflecting the `unit-test` job result.

## Runner Selection

Connected repositories download and run [`ci-build-create-runner.sh`](.github/workflows/ci-build-create-runner.sh) from `main`.

Runner sizing is derived from the triggering tag, but only for `novatalks.core` (see below). All other repositories always resolve to `small`, regardless of tag — the switcher only routes test tags to the large test matrix for `novatalks.core`, so a large VM would be wasted on any other repository's test tag.

The script:

- fetches the full Hetzner server list with pagination (`per_page=50`), so cap counts are not truncated to the API's default first page of 25 servers
- checks existing GitHub self-hosted runners named `dev-00-gh-runner-*`
- reuses an online idle runner whose size priority is at least the required size
- enforces a global `MAX_TOTAL_RUNNERS` cap (env-overridable, default `6`) counting **all** `dev-00-gh-runner-*` Hetzner servers in any status, across all sizes; when the cap is reached the run is sent to the wait queue (`runner_need=false`) regardless of per-size counts
- otherwise counts per-size Hetzner servers (`starting`, `initializing`, or `running` of the required `server_type`) directly from the Hetzner API response, and creates up to two runners per required size
- emits `runner_need`, `runner_labels`, `runner_size`, and `runner_name`

A random 0-9 second jitter sleep runs before the Hetzner/GitHub lookups to reduce (not eliminate) create races between concurrent triggers.

For PR events there is no tag, so the current default runner size is `small`.

### Runner Sizing (novatalks.core)

`novatalks.core` uses a differentiated sizing matrix because different tag types have very different resource requirements. The sizing is resolved in [`ci-build-create-runner.sh`](.github/workflows/ci-build-create-runner.sh) downloaded from `nova.ci@main`:

| Tag substring | `test_mode` | Runner size | Hetzner type | Why |
| --- | --- | --- | --- | --- |
| `build` | — | `small` | cx33 | lint + build only |
| `unit-test` | `unit` | `medium` | cx43 | unit tests are CPU-bound, no DB services |
| `int-test` / `full-test` | `integration` / `both` | `large` | cx53 | integration needs postgres + redis + app |
| anything else | — | `small` | cx33 | default |

`unit-test` is matched before the generic `test` check, so unit-only runs get `medium` while `int-test` and `full-test` get `large`.

Because one tag push provisions **one** runner size for the entire run, a `full-test` tag executes both unit and integration tests on the `large` runner (acceptable; only unit-only runs get `medium`). The `integration-tests` job runs after `unit-tests` (`needs: [unit-tests]`), so a `full-test` run occupies a single `large` runner sequentially instead of two in parallel.

Each size class (`small`, `medium`, `large`) has its own **max-2** concurrency cap, measured directly from Hetzner server state (`starting`/`initializing`/`running` servers of the size's `server_type`) rather than GitHub runner registrations, so in-flight VM creations are counted and offline "ghost" GitHub registrations are not. `medium` and `large` are independent pools, so unit-test (`medium`) and integration-test (`large`) runs do not contend for the same runners. All size pools additionally share the global `MAX_TOTAL_RUNNERS` cap described above.

All other standard build repositories always use `small`, regardless of tag.

## Validation

The repository ships a single validation harness that runs every check below:

```bash
./scripts/validate.sh   # or: make validate
```

The harness ([`scripts/validate.sh`](scripts/validate.sh)) runs:

- a YAML parser against all `.github/workflows/*.yaml` files
- a YAML parser against all `.github/actions/*/action.yml` files
- `git diff --check` (whitespace)
- a `.agents` ↔ `.claude` skill mirror sync check
- `actionlint` when it is available locally — **advisory** by default (the repo carries a pre-existing backlog of shellcheck-info / expression findings, so they are reported but do not fail the harness); set `STRICT_ACTIONLINT=1` to enforce once the backlog is cleared

It is also wired into CI: [`ci-self-validate.yaml`](.github/workflows/ci-self-validate.yaml) runs the harness (with `actionlint` installed) on every pull request and on pushes to `main`, so workflow and action changes are validated automatically.

After changing CI behavior, still verify by hand that README, [`CLAUDE.md`](CLAUDE.md), [`AGENTS.md`](AGENTS.md), and the skill at [`.agents/skills/nova-ci/SKILL.md`](.agents/skills/nova-ci/SKILL.md) (with its `.claude/` mirror) describe the same routing behavior.

## Tests

### Unit Tests (Build Gate)

A `unit-test` job runs as a fast parallel gate in [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml) alongside `linter`, on both PR and non-PR events.

The job is repo-aware via a "Resolve test plan" step. Currently only `novatalks.core` runs unit tests (`npm run test:unit`). All other standard build repositories resolve to a no-op success, so they are unaffected and backward compatible. To enable unit tests for a new repository, add a case in that step.

Unit tests use `npm run test:unit` (jest `--selectProjects unit`, parallel via jest workers). There is no `continue-on-error`.

**PR pipeline:** lint + unit tests only. No image build, no scan, no notification. A unit test failure makes the PR check red.

**Non-PR pipeline:** lint + unit tests, then image build (gated on unit test success), then Trivy scan, then notification. Lint failure is advisory; unit test failure blocks the build.

### Test Workflow Modes

[`ci-build-ntk-on-push-tags-run-test.yaml`](.github/workflows/ci-build-ntk-on-push-tags-run-test.yaml) accepts a `test_mode` input with three values:

| `test_mode` | What runs | Trigger tag substring |
| --- | --- | --- |
| `unit` | unit tests only (no DB or Redis services) | `unit-test` |
| `integration` | integration tests (postgres:16 + redis:8 services) | `int-test` |
| `both` | unit tests then integration tests | `full-test` |

Default is `integration` (backward compatible with existing `int-test` tags).

In `both` mode the suites run sequentially: `integration-tests` has `needs: [unit-tests]` with a `!cancelled()` condition, so integration still runs when `unit-tests` is skipped (`integration` mode) or failed (`both` mode — the suites report independently in the notifier), and a `full-test` run needs only one runner.

**Tag conventions for `novatalks.core`:**

```bash
git tag int-test-NC2-1234 && git push origin int-test-NC2-1234   # integration only
git tag unit-test-NC2-1234 && git push origin unit-test-NC2-1234 # unit only
git tag full-test-NC2-1234 && git push origin full-test-NC2-1234 # both
```

The three substrings (`int-test`, `unit-test`, `full-test`) do not collide. The switcher computes the `test_mode` from the tag and passes it to the test workflow.

The workflow also has a `workflow_dispatch` trigger with a `test_mode` choice input for manual runs inside `nova.ci` without pushing a tag.

### Integration Tests

Integration tests use `npm run test:integration` (which already includes `--runInBand --forceExit --silent --verbose`). The integration job uses redis:8 services shared across all steps. There is no `continue-on-error`; failures now fail the job (previously they were masked).

The Postgres service image is repository-aware:

- `novatalks.core`: uses the official `postgres:17.9-trixie` image (PG 17.9 on Debian trixie), matching the production major version.
- All other repositories (e.g. `novatalks.ui`): use `postgres:16`.

The `POSTGRES_*` env vars, `pg_isready` health check, and `CREATE EXTENSION pgcrypto` step are the same for all repositories.

File storage is also repository-aware. For `novatalks.core` only, a `Configure S3 (Cloudflare R2) file storage` step runs before the integration tests and writes `FILE_DRIVER=s3` plus the `AWS_S3_*` settings to `$GITHUB_ENV`, sourced from the repository secrets `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, and `R2_BUCKET` (region `auto`, path-style on). The step is gated on `github.event.repository.name == 'novatalks.core'`, so other repositories (e.g. `novatalks.ui`) keep their default `FILE_DRIVER`. Secrets reach the reusable workflow via the switcher's `secrets: inherit`.

npm dependencies are cached via setup-node `cache: npm`.

**Integration test sharding** (jest `--shard` + matrix) is intentionally not enabled by default. Integration tests share database state and run with `--runInBand`. To parallelize, each shard would need its own postgres and Redis service and a `--shard=i/N` flag. Unit tests already parallelize via jest workers; the integration bottleneck is DB I/O, not CPU.

### Reading Failures

- `unit-test` job red in a build or PR: the build is blocked and the PR check fails. Fix the failing unit test or code before merging or triggering a build.
- `integration-tests` job red: a real integration failure (no longer hidden). Investigate via the `integration-test-report` artifact in the workflow run.
- Lint failure alone does not block the build (advisory) but is reported in the notifier message.

### CI Timing Note

The integration test runner was updated from a file-by-file loop (which spawned a new Node.js process per file) to the native jest runner via `npm run test:integration`. This eliminates per-file Node restart overhead.

Measured wall-clock durations from Actions run timings (fill in after observing runs on the target runner):

- Before: ___ min
- After: ___ min

## Implemented Workflows

Current reusable workflows in [`.github/workflows`](.github/workflows):

- [`ci-build-trigger-switcher.yaml`](.github/workflows/ci-build-trigger-switcher.yaml): central dispatcher
- [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml): lint, build, publish, and notify for container images
- [`ci-build-ntk-on-push-direct-to-protected-branches.yaml`](.github/workflows/ci-build-ntk-on-push-direct-to-protected-branches.yaml): fails direct pushes to protected branches
- [`ci-build-ntk-on-push-branches.yaml`](.github/workflows/ci-build-ntk-on-push-branches.yaml): placeholder flow for selected branch builds
- [`ci-build-ntk-on-push-tags-run-test.yaml`](.github/workflows/ci-build-ntk-on-push-tags-run-test.yaml): test runner for `int-test`, `unit-test`, and `full-test` tags; accepts `test_mode` (unit/integration/both, default integration)
- [`ci-build-ntk-on-push-tags-run-e2e.yaml`](.github/workflows/ci-build-ntk-on-push-tags-run-e2e.yaml): reusable E2E test flow
- [`ci-e2e-tests-manual.yaml`](.github/workflows/ci-e2e-tests-manual.yaml): reusable Playwright E2E flow invoked by the switcher for tagged test runs
- [`ci-build-ntk-on-push-tags-gh-deploy.yaml`](.github/workflows/ci-build-ntk-on-push-tags-gh-deploy.yaml): GitHub Pages deploy
- [`ci-build-ntk-on-push-tags-widget-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-widget-build.yaml): chat widget build flow
- [`ci-build-ntk-on-push-tags-mob-apk-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-mob-apk-build.yaml): internal mobile APK build
- [`ci-build-ntk-on-push-tags-mob-apk-build-public.yaml`](.github/workflows/ci-build-ntk-on-push-tags-mob-apk-build-public.yaml): public mobile APK build
- [`ci-build-ntk-on-push-tags-mob-pwa-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-mob-pwa-build.yaml): mobile PWA, SPA, and CRM build flow
- [`ci-build-ntk-on-push-tags-flows-to-pub.yaml`](.github/workflows/ci-build-ntk-on-push-tags-flows-to-pub.yaml): publish botflow assets

This repository also defines one non-reusable meta workflow:

- [`ci-self-validate.yaml`](.github/workflows/ci-self-validate.yaml): runs [`scripts/validate.sh`](scripts/validate.sh) on pull requests and pushes to `main` to validate this repo's own workflows, actions, and agent docs

## Internal Actions

Current internal reusable actions in [`.github/actions`](.github/actions):

- [`action-cond/action.yml`](.github/actions/action-cond/action.yml): composite replacement for deprecated `haya14busa/action-cond`
- [`install-docker/action.yml`](.github/actions/install-docker/action.yml): ensures Docker CLI and daemon are available before Docker-based actions or Buildx steps run on self-hosted runners

`action-cond` preserves the previous interface:

- input `cond`
- input `if_true`
- input `if_false`
- output `value`

Notifier workflows use `action-cond` to select success or failure messages before sending Telegram and Google Chat notifications.

## Agent Context

This repository includes agent-facing context for both Codex-compatible agents and Claude Code:

- [`CLAUDE.md`](CLAUDE.md): canonical agent guidance for Claude Code and Codex
- [`AGENTS.md`](AGENTS.md): Codex-compatible entry point that delegates to `CLAUDE.md`
- [`.agents/skills/nova-ci/SKILL.md`](.agents/skills/nova-ci/SKILL.md): portable Nova CI maintenance skill shared across LLMs
- [`.claude/skills/nova-ci/SKILL.md`](.claude/skills/nova-ci/SKILL.md): Claude Code mirror of the skill

Keep these files synchronized with this README whenever CI behavior changes.
