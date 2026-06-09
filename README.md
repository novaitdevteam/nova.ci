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
| `push` | standard build repositories | tag ref contains `build` | [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml) |
| `push` | standard build repositories | branch push commit message contains `build` | [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml) |
| `pull_request` | `novatalks.core` | non-draft PR on `opened`, `synchronize`, `reopened`, or `ready_for_review` | [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml) with `build-engine` and `build-reporting` matrix |
| `pull_request` | standard PR build repositories | non-draft PR on `opened`, `synchronize`, `reopened`, or `ready_for_review` | [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml) with `build_target: build` |
| `push` | `novatalks.engine`, `novatalks.core` | tag contains `int-test` | [`ci-build-ntk-on-push-tags-run-test.yaml`](.github/workflows/ci-build-ntk-on-push-tags-run-test.yaml) |
| `push` | `nova.docs` | tag contains `build` | [`ci-build-ntk-on-push-tags-gh-deploy.yaml`](.github/workflows/ci-build-ntk-on-push-tags-gh-deploy.yaml) |
| `push` | `novatalks.ui-lite` | tag contains `build-apk` | [`ci-build-ntk-on-push-tags-mob-apk-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-mob-apk-build.yaml) |
| `push` | `novatalks.mobile` | tag contains `build-apk` | [`ci-build-ntk-on-push-tags-mob-apk-build-public.yaml`](.github/workflows/ci-build-ntk-on-push-tags-mob-apk-build-public.yaml) |
| `push` | `novatalks.ui-lite` | tag contains `build-pwa`, `build-spa`, or `build-crm` | [`ci-build-ntk-on-push-tags-mob-pwa-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-mob-pwa-build.yaml) |
| `push` | `novatalks.chatwidget` | tag contains `build` | [`ci-build-ntk-on-push-tags-widget-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-widget-build.yaml) |
| `push` | any repository | branch name contains `build-me-please` | [`ci-build-ntk-on-push-branches.yaml`](.github/workflows/ci-build-ntk-on-push-branches.yaml) |
| `push` | `novatalks.botflow.flows` | tag contains `build` | [`ci-build-ntk-on-push-tags-flows-to-pub.yaml`](.github/workflows/ci-build-ntk-on-push-tags-flows-to-pub.yaml) |
| `push` | `novatalks.tests` | any tag | [`ci-e2e-tests-manual.yaml`](.github/workflows/ci-e2e-tests-manual.yaml) |

Standard build repositories:

- `novatalks.engine`
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

Pull request builds do not create Git tags. Instead, the switcher passes a synthetic `build_target` into [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml).

For `novatalks.core`, every supported non-draft PR event runs two builds:

- `build-engine`
- `build-reporting`

For other standard PR build repositories, the switcher passes:

```yaml
build_target: build
```

That makes PR builds follow the same build workflow used by `build*` tags, while still using the PR branch as the image ref label.

## Build Workflow

[`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml) accepts:

- `runner_labels`: optional runner label override
- `build_target`: optional synthetic build selector used mainly by PR dispatch

When `build_target` is empty, the workflow resolves behavior from `github.ref_name`. When `build_target` is set, it is used for lint and Dockerfile selection.

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

## Runner Selection

Connected repositories download and run [`ci-build-create-runner.sh`](.github/workflows/ci-build-create-runner.sh) from `main`.

Runner sizing is derived from the triggering tag:

- tag contains `build` -> `small`
- tag contains `test` -> `large`
- anything else -> `small`

The script:

- checks existing GitHub self-hosted runners named `dev-00-gh-runner-*`
- checks Hetzner servers currently starting or initializing
- reuses an online idle runner whose size priority is at least the required size
- creates up to two runners per required size
- emits `runner_need`, `runner_labels`, `runner_size`, and `runner_name`

For PR events there is no tag, so the current default runner size is `small`.

## Validation

Before merging workflow changes:

- run a YAML parser against changed `.github/workflows/*.yaml` files
- run a YAML parser against changed `.github/actions/*/action.yml` files
- run `git diff --check`
- run `actionlint` when it is available locally
- verify README, [`AGENTS.md`](AGENTS.md), [`CLAUDE.md`](CLAUDE.md), and [`skills/nova-ci/SKILL.md`](skills/nova-ci/SKILL.md) still describe the same routing behavior

## Implemented Workflows

Current reusable workflows in [`.github/workflows`](.github/workflows):

- [`ci-build-trigger-switcher.yaml`](.github/workflows/ci-build-trigger-switcher.yaml): central dispatcher
- [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml): lint, build, publish, and notify for container images
- [`ci-build-ntk-on-push-direct-to-protected-branches.yaml`](.github/workflows/ci-build-ntk-on-push-direct-to-protected-branches.yaml): fails direct pushes to protected branches
- [`ci-build-ntk-on-push-branches.yaml`](.github/workflows/ci-build-ntk-on-push-branches.yaml): placeholder flow for selected branch builds
- [`ci-build-ntk-on-push-tags-run-test.yaml`](.github/workflows/ci-build-ntk-on-push-tags-run-test.yaml): integration test runner for `int-test` tags
- [`ci-build-ntk-on-push-tags-run-e2e.yaml`](.github/workflows/ci-build-ntk-on-push-tags-run-e2e.yaml): reusable E2E test flow
- [`ci-e2e-tests-manual.yaml`](.github/workflows/ci-e2e-tests-manual.yaml): reusable Playwright E2E flow invoked by the switcher for tagged test runs
- [`ci-build-ntk-on-push-tags-gh-deploy.yaml`](.github/workflows/ci-build-ntk-on-push-tags-gh-deploy.yaml): GitHub Pages deploy
- [`ci-build-ntk-on-push-tags-widget-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-widget-build.yaml): chat widget build flow
- [`ci-build-ntk-on-push-tags-mob-apk-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-mob-apk-build.yaml): internal mobile APK build
- [`ci-build-ntk-on-push-tags-mob-apk-build-public.yaml`](.github/workflows/ci-build-ntk-on-push-tags-mob-apk-build-public.yaml): public mobile APK build
- [`ci-build-ntk-on-push-tags-mob-pwa-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-mob-pwa-build.yaml): mobile PWA, SPA, and CRM build flow
- [`ci-build-ntk-on-push-tags-flows-to-pub.yaml`](.github/workflows/ci-build-ntk-on-push-tags-flows-to-pub.yaml): publish botflow assets

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

- [`AGENTS.md`](AGENTS.md): shared working instructions for coding agents
- [`CLAUDE.md`](CLAUDE.md): Claude Code project context
- [`skills/nova-ci/SKILL.md`](skills/nova-ci/SKILL.md): portable Nova CI maintenance skill

Keep these files synchronized with this README whenever CI behavior changes.
