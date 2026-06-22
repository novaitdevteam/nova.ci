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
- `.github/workflows/ci-build-create-runner.sh`: runner selection helper downloaded by product repo callers
- `.github/actions/action-cond/action.yml`: success/failure message selector used by notifier jobs
- `.github/actions/install-docker/action.yml`: Docker prerequisite helper for Docker build jobs

## Workflow Model

Product repositories usually keep a local `.github/workflows/ci-build-trigger.yaml` workflow. That caller handles events and runner setup, then calls:

```yaml
uses: novaitdevteam/nova.ci/.github/workflows/ci-build-trigger-switcher.yaml@main
secrets: inherit
```

Keep dispatch behavior in `ci-build-trigger-switcher.yaml`, not in product repository callers, unless the task explicitly asks to change caller behavior.

## Dispatch Rules To Preserve

- Push to `master` or `development` in standard build repositories fails via the protected-branch workflow.
- Push tags containing `build` in standard build repositories call the main build workflow.
- Branch pushes whose head commit message contains `build` call the main build workflow.
- Non-draft `pull_request` events on `opened`, `synchronize`, `reopened`, and `ready_for_review` call the main build workflow, but run lint only: the `build-image` and notifier jobs are gated on `github.event_name != 'pull_request'`.
- `novatalks.core` PRs lint two targets: `build-engine` and `build-reporting`.
- Other standard PR build repositories lint with `build_target: build`.
- Integration tests for `novatalks.engine` and `novatalks.core` use tags containing `int-test`.
- Specialized tag workflows exist for docs, mobile APK/PWA/SPA/CRM, chat widget, botflow assets, and Playwright tests.

Standard build repositories currently are:

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

Pull request events are lint-only. Keep the `build-image` and notifier jobs gated on `github.event_name != 'pull_request'` so PRs never build or publish an image.

PR builds must not delete tags. Keep tag deletion guarded by `github.ref_type == 'tag' && inputs.build_target == ''`.

Image tag ref labels should use `github.head_ref` for PRs and be sanitized for Docker compatibility.

Mobile PWA/SPA/CRM image tags should keep variant suffixes before the short SHA, matching the main build workflow:

```text
<release>_<short-ref-name><image-suffix>_<short-sha>
```

Use `_pwa`, `_spa`, and `_crm` for the corresponding mobile web build tags.

Mobile APK workflows should keep Node.js at `22.22.0` or newer because current Quasar/Icongenie tooling requires at least that Node version.

## Runner Tooling Semantics

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

## Documentation Sync

When changing CI behavior, update all relevant agent/human documentation in the same change:

- `README.md`
- `AGENTS.md`
- `CLAUDE.md`
- `.agents/skills/nova-ci/SKILL.md` (and its mirror `.claude/skills/nova-ci/SKILL.md`)

Keep README as the canonical broad reference. Keep this skill concise and procedural.

## Validation

Run YAML parsing and whitespace checks:

```bash
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f); puts "OK #{f}" }' .github/workflows/*.yaml
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f); puts "OK #{f}" }' .github/actions/*/action.yml
git diff --check
```

Run `actionlint` if installed.

Review diffs for the files that define behavior:

```bash
git diff -- .github/workflows .github/actions README.md AGENTS.md CLAUDE.md .agents/skills/nova-ci/SKILL.md .claude/skills/nova-ci/SKILL.md
```

If product repository callers were touched, verify the user explicitly requested that and check those repositories separately.
