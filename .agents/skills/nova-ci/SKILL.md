---
name: nova-ci
description: Use when changing, reviewing, or documenting the NovaTalks shared CI repository nova.ci, including GitHub Actions reusable workflows, ci-build-trigger-switcher routing, PR build_target behavior, runner selection, Docker image tags, and agent documentation.
metadata:
  author: novatalks
  version: '1.0.0'
---

# Nova CI Skill

## Scope

Use this skill for work in `novaitdevteam/nova.ci`. The repo owns shared reusable GitHub Actions workflows used by multiple NovaTalks product repositories.

Primary files:

- `README.md`: canonical human-facing documentation
- `AGENTS.md`: Codex-compatible agent instructions
- `CLAUDE.md`: Claude Code project instructions
- `.github/workflows/ci-build-trigger-switcher.yaml`: central dispatcher
- `.github/workflows/ci-build-ntk-on-push-tags-build.yaml`: main lint/build/publish workflow
- `.github/workflows/ci-build-ntk-on-push-tags-run-test.yaml`: test runner workflow (unit/integration/both)
- `.github/workflows/ci-build-create-runner.sh`: runner selection helper downloaded by product repo callers
- `.github/actions/action-cond/action.yml`: success/failure message selector used by notifier jobs
- `.github/actions/install-docker/action.yml`: Docker prerequisite helper for Docker build jobs
- `scripts/validate.sh`: validation harness (YAML, whitespace, skill mirror, actionlint); also `make validate`
- `.github/workflows/ci-self-validate.yaml`: CI that runs the harness on PRs and pushes to `main`

## Workflow Model

Product repositories usually keep a local `.github/workflows/ci-build-trigger.yaml` workflow. That caller handles events and runner setup, then calls:

```yaml
uses: novaitdevteam/nova.ci/.github/workflows/ci-build-trigger-switcher.yaml@main
secrets: inherit
```

Keep dispatch behavior in `ci-build-trigger-switcher.yaml`, not in product repository callers, unless the task explicitly asks to change caller behavior.

## Dispatch Rules To Preserve

- Push to `master` or `development` in standard build repositories fails via the protected-branch workflow.
- Push tags containing `build`, or starting with `scan`, in standard build repositories call the main build workflow.
- Branch pushes whose head commit message contains `build` call the main build workflow.
- Non-draft `pull_request` events on `opened`, `synchronize`, `reopened`, and `ready_for_review` call the main build workflow, but run lint and unit tests only: the `build-image`, `trivy-scan`, and notifier jobs are gated on `github.event_name != 'pull_request'`.
- `novatalks.core` PRs lint two targets: `build-engine` and `build-reporting`; unit tests run once on `build-engine` and are skipped on `build-reporting`.
- Other standard PR build repositories lint with `build_target: build`.
- Tags containing `int-test` → `ci-build-ntk-on-push-tags-run-test.yaml` with `test_mode: integration` (backward compatible).
- Tags containing `unit-test` → `ci-build-ntk-on-push-tags-run-test.yaml` with `test_mode: unit`.
- Tags containing `full-test` → `ci-build-ntk-on-push-tags-run-test.yaml` with `test_mode: both`.
- The three test tag substrings (`int-test`, `unit-test`, `full-test`) do not collide.
- Specialized tag workflows exist for docs, mobile APK/PWA/SPA/CRM, chat widget, botflow assets, and Playwright tests.

Standard build repositories currently are:

- `novatalks.core`
- `novatalks.ui`
- `nova.botflow`
- `nova.chatsconnector.telegram-client-api`
- `novatalks.dialer`
- `nova.chatsconnector.genesys.cloud.premium.wizard.engine`
- `novatalks.geoip-api`
- `nova.chatsconnector.whatsapp-client-api`
- `novatalks.uspacy.connector`

`novatalks.core` is excluded from the generic PR build route because it has dedicated PR targets.

## Build Target Semantics

`ci-build-ntk-on-push-tags-build.yaml` accepts optional `build_target`.

- Empty `build_target`: resolve lint and Dockerfile selection from `github.ref_name`.
- Non-empty `build_target`: use it as a synthetic build selector.
- `build-engine`: engine lint, `docker/engine.Dockerfile`, suffix `_engine`.
- `build-reporting`: reporting lint, `docker/reporting.Dockerfile`, suffix `_reporting`.
- `build-restore-historical`: `docker/restore-historical.Dockerfile`, suffix `_restore-historical`.
- `build-message-source-id`: `docker/message-source-id.Dockerfile`, suffix `_migrate-message-source-id`.
- `build` or any default target: `docker/server.Dockerfile`, no suffix.

Pull request events run lint and unit tests only. Keep the `build-image` and notifier jobs gated on `github.event_name != 'pull_request'` so PRs never build or publish an image.

PR builds must not delete tags. Keep tag deletion guarded by `github.ref_type == 'tag' && inputs.build_target == ''`.

Image tag ref labels should use `github.head_ref` for PRs and be sanitized for Docker compatibility.

Mobile PWA/SPA/CRM image tags should keep variant suffixes before the short SHA, matching the main build workflow:

```text
<release>_<short-ref-name><image-suffix>_<short-sha>
```

Use `_pwa`, `_spa`, and `_crm` for the corresponding mobile web build tags.

Mobile APK workflows should keep Node.js at `22.22.0` or newer because current Quasar/Icongenie tooling requires at least that Node version.

## Test Execution Semantics

### Unit Test Gate (ci-build-ntk-on-push-tags-build.yaml)

A `unit-test` job runs in parallel with `linter` on both PR and non-PR events. It is repo-aware via a "Resolve test plan" step. Currently only `novatalks.core` runs `npm run test:unit`; all other standard build repos resolve to a no-op success. To enable unit tests for a new repository, add a case in that step.

`build-image` has `needs: [linter, unit-test]`. The condition is `!cancelled() && github.event_name != 'pull_request' && needs.unit-test.result == 'success'`. Lint is advisory (build runs even if lint fails). A unit test failure blocks the build.

PR pipeline: `linter` + `unit-test` only. No image build. A unit test failure fails the PR check.

Do not add `continue-on-error` to the `unit-test` job. Keep the gate backward-compatible: repos without a unit test plan must resolve to no-op success, not error.

The notifier includes a `Unit Tests Status:` line (✅/❌) in the build message alongside the ESLinter status.

### Test Workflow Modes (ci-build-ntk-on-push-tags-run-test.yaml)

The test workflow accepts `test_mode: unit | integration | both` (default `integration`). The switcher derives `test_mode` from the tag substring and passes it as a workflow input.

| Tag substring | `test_mode` |
| --- | --- |
| `int-test` | `integration` |
| `unit-test` | `unit` |
| `full-test` | `both` |

The workflow also has a `workflow_dispatch` trigger with a `test_mode` choice input for manual runs.

Separate jobs: `unit-tests` (runs when mode is `unit` or `both`, no DB services) and `integration-tests` (runs when mode is `integration` or `both`, with redis:8 and a Postgres service). `integration-tests` has `needs: [unit-tests]` with a `!cancelled()` condition: in `both` mode the suites run sequentially on one runner (integration still runs if unit fails; suites report independently), and in `integration` mode the skipped `unit-tests` job does not block it. A `delete-tag` job deletes the trigger tag via `actions/github-script@v8` `git.deleteRef` (no third-party action).

The Postgres service image is repository-aware: `novatalks.core` uses the official `postgres:17.9-trixie` image (PG 17.9 on Debian trixie, matching the production major version), selected via `github.event.repository.name == 'novatalks.core'`; all other repositories (e.g. `novatalks.ui`) use `postgres:16`. The `POSTGRES_*` env vars, `pg_isready` health check, and `CREATE EXTENSION pgcrypto` step are unchanged across all repos.

File storage is repository-aware too: a `Configure S3 (Cloudflare R2) file storage` step, gated on `github.event.repository.name == 'novatalks.core'`, writes `FILE_DRIVER=s3` and the `AWS_S3_*` settings to `$GITHUB_ENV` before the integration run, from repo secrets `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET` (region `auto`, force path style). Keep it scoped to `novatalks.core` so other repos keep their default `FILE_DRIVER`, and keep the `R2_*` secrets routed via step `env:` (not inline `${{ secrets }}` in `run`). Secrets reach the reusable workflow through the switcher's `secrets: inherit`.

Both test jobs use npm scripts: `npm run test:unit` and `npm run test:integration` (the integration script already includes `--runInBand --forceExit --silent --verbose`). Do not replace them with raw `npx jest` flags in CI. No `continue-on-error` on either job; integration failures now fail the job (they were previously masked).

npm dependencies are cached via setup-node `cache: npm`.

Integration test sharding (jest `--shard` + matrix) is intentionally not enabled by default. Integration tests share database state and run with `--runInBand`. To parallelize, each shard would need its own postgres and Redis service plus `--shard=i/N`. Unit tests already parallelize via jest workers.

## Runner Tooling Semantics

Runner sizing is resolved in `ci-build-create-runner.sh` (downloaded from `nova.ci@main` by product-repo callers). For **`novatalks.core` only**, sizing is differentiated by tag substring:

| Tag substring | `test_mode` | Runner size | Hetzner type | Why |
| --- | --- | --- | --- | --- |
| `build` | — | `small` | cx33 | lint + build only |
| `unit-test` | `unit` | `medium` | cx43 | unit tests, no DB services |
| `int-test` / `full-test` | `integration` / `both` | `large` | cx53 | needs postgres + redis + app |
| anything else | — | `small` | cx33 | default |

`unit-test` is matched before the generic `test` check so unit-only runs get `medium` while `int-test`/`full-test` get `large`. The matrix applies only to real tag pushes (`refs/tags/*`); branch and PR refs always resolve to `small`, so a branch name containing `test` does not provision a large VM. A `full-test` tag runs both unit and integration tests sequentially on a single `large` runner (one tag push = one runner size; `integration-tests` needs `unit-tests`). Each size class has its own **max-2** concurrency cap; `medium` and `large` are independent pools. All other repositories always resolve to `small`, regardless of tag.

The reuse check only picks GitHub-registered runners (online, idle, size priority ≥ required) whose backing Hetzner VM is in `running` status — registrations whose VM is deleting or gone (ghosts) are skipped, since a job queued on them would never start. Per-size counts are computed directly from the Hetzner API response (servers named `dev-00-gh-runner-*` with a matching `server_type` in `starting`, `initializing`, or `running` status), not from GitHub-registered runners, so in-flight VM creations are counted and offline "ghost" GitHub registrations (left over from failed creates) don't block new ones. A global `MAX_TOTAL_RUNNERS` guard (env-overridable, default `6`) counts every `dev-00-gh-runner-*` Hetzner server in any status across all sizes; once that total is reached, new triggers go to the wait queue regardless of per-size counts. The race-jitter sleep before these lookups is 0-9 seconds.

Before emitting `runner_need=true`, the script takes a short-TTL **create lock** to close the check-then-act race between concurrent triggers (the winner's VM is not yet visible to the per-size count while it is being created). The lock is a **Hetzner placement group** named `runner-create-lock-<size>` in the runner VMs' own Hetzner project: placement group names are unique per project, so the create is atomic (`uniqueness_error` = somebody else won), and it is written with the same `HCLOUD_TOKEN` every caller already passes to create VMs — org-wide scope, no extra credentials, no GitHub permissions (GitHub-ref lock variants all failed on token scope; SSH-key objects were rejected because their creation emails account notifications). The group's `epoch` label is the acquisition timestamp. A lock younger than `RUNNER_LOCK_TTL_SECONDS` (default 60s) sends the run to the wait queue with a `::notice::`; a stale lock (older, far-future, or unreadable epoch) is deleted and re-acquired; nobody releases the lock explicitly (TTL expiry hands the guard back to the per-size count). All lock-machinery failures fail **open** — create without the lock plus a `::warning::` — so an API problem can never block runner creation. Keep the lock in Hetzner, org-wide, and fail-open.

Docker build jobs should call `.github/actions/install-docker/action.yml` before Docker login, Buildx setup, or image builds. Keep Docker setup out of notifier jobs.

Mobile PWA/SPA/CRM builds use a named Docker context `builder`; create it idempotently with `docker context inspect builder >/dev/null 2>&1 || docker context create builder`.

Mobile APK workflows should not assume the self-hosted runner image has all Android tooling preinstalled. Preserve these setup behaviors:

- install `zip` and `unzip` before Gradle setup
- resolve Android SDK from `ANDROID_SDK_ROOT` or `ANDROID_HOME`, with common self-hosted runner fallbacks
- install `platform-tools`, `platforms;android-35`, and `build-tools;35.0.0` with `sdkmanager`
- write `src-capacitor/android/local.properties` with the resolved `sdk.dir`
- locate and use `apksigner` under the resolved SDK

## Notification Semantics

Notifier jobs use `.github/actions/action-cond/action.yml` to select message text.

Telegram and Google Chat notifications should use `actions/github-script@v8` with Node.js `fetch`. Do not reintroduce Docker-based Telegram actions such as `appleboy/telegram-action`; notifier jobs should not require Docker.

In `ci-build-ntk-on-push-tags-build.yaml` the notifier `needs: [build-image, linter, unit-test, trivy-scan]` and a `Compose Trivy line` step builds a scan line color-coded by worst severity (`🔴 CRITICAL found!` / `🟠 HIGH found` / `🟢 clean`, plus `❌ FAILED` under a fail mode or `⏭️ skipped`), with CRITICAL/HIGH counts and the report link, from `trivy-scan` outputs, injected into the same message sent to Telegram and Google Chat. The message also includes a `Unit Tests Status:` line (✅/❌) from the `unit-test` job result. The job summary uses a matching colored alert banner (CAUTION/WARNING/NOTE).

## Trivy Image Scan Semantics

`ci-build-ntk-on-push-tags-build.yaml` has a `trivy-scan` job that `needs: [build-image]` and scans the exact GHCR image the build produced:

```text
ghcr.io/<owner>/<repo>:<release>_<short-ref-name><image-suffix>_<short-sha>
```

Preserve these behaviors:

- Keep the scan gated on `github.event_name != 'pull_request'` and `needs.build-image.result == 'success'`. PRs stay lint and unit tests only (no scan).
- The `Resolve scan policy` step auto-enables the scan when `SHORT_REF_NAME` is `main`, `master`, or `development`, and enables it on demand when the trigger tag ref starts with `scan` (`[[ "$REF_NAME" == scan* ]]`). Otherwise the image is built but not scanned. Branch/repo/commit come from push metadata, not the tag name.
- The switcher routes `push` tags containing `build` or starting with `scan` to the build workflow, so a `scan*` tag builds and scans a specific branch.
- Scan with `aquasecurity/trivy-action@v0.36.0` (pinned). Run an OS pass (`TRIVY_PKG_TYPES=os`), a library pass (`TRIVY_PKG_TYPES=library`), and a JSON pass for counts; reuse the install with `skip-setup-trivy: true`. The action manages the vulnerability and Java DBs — do not reintroduce a manual `--download-db-only` / `--download-java-db-only` two-step.
- Cache the Trivy DB with `actions/cache` over `${{ github.workspace }}/.cache/trivy` (action cache disabled via `cache: false`); the key embeds a 5-hour bucket (`trivy-db-5h-<floor(epoch/18000)>`).
- Emit a single `.report` file (`trivy-<repo>-<ref><suffix>-<sha>.report`) with `=== OS Vulnerabilities ===` and `=== Node.js Vulnerabilities ===` sections. Upload it as a workflow artifact and attach it to a GitHub prerelease tagged `TRIVY.SCAN_<release>_<ref><suffix>_<sha>` (`softprops/action-gh-release@v2`, job needs `contents: write`). Put CRITICAL/HIGH counts and the report link in the job summary.
- `trivy_mode` policy: `warn-only` (default) always succeeds and only warns; `fail-on-critical` fails the job when CRITICAL > 0; `fail-on-high` fails when CRITICAL or HIGH > 0. The image is already built/pushed before the scan, so a failing scan signals red but does not unpublish it.

## Documentation Sync

When changing CI behavior, update all relevant agent/human documentation in the same change:

- `README.md`
- `AGENTS.md`
- `CLAUDE.md`
- `.agents/skills/nova-ci/SKILL.md` (and its mirror `.claude/skills/nova-ci/SKILL.md`)

Keep README as the canonical broad reference. Keep this skill concise and procedural.

## Validation

Run the validation harness; it bundles every check (YAML parse of workflows and
actions, `git diff --check`, `.agents` ↔ `.claude` skill mirror sync, and
`actionlint` when installed — advisory by default given the repo's pre-existing
backlog; `STRICT_ACTIONLINT=1` enforces):

```bash
./scripts/validate.sh   # or: make validate
```

The same harness runs in CI via `ci-self-validate.yaml` on pull requests and pushes
to `main`. After it passes, review diffs for the files that define behavior:

```bash
git diff -- .github/workflows .github/actions scripts README.md AGENTS.md CLAUDE.md .agents/skills/nova-ci/SKILL.md .claude/skills/nova-ci/SKILL.md
```

If product repository callers were touched, verify the user explicitly requested that and check those repositories separately.
