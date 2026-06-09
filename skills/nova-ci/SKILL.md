---
name: nova-ci
description: Use when changing, reviewing, or documenting the NovaTalks shared CI repository nova.ci, including GitHub Actions reusable workflows, ci-build-trigger-switcher routing, PR build_target behavior, runner selection, Docker image tags, and agent documentation.
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
- Non-draft `pull_request` events on `opened`, `synchronize`, `reopened`, and `ready_for_review` call the main build workflow.
- `novatalks.core` PRs run two targets: `build-engine` and `build-reporting`.
- Other standard PR build repositories run with `build_target: build`.
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

PR builds must not delete tags. Keep tag deletion guarded by `github.ref_type == 'tag' && inputs.build_target == ''`.

Image tag ref labels should use `github.head_ref` for PRs and be sanitized for Docker compatibility.

Mobile PWA/SPA/CRM image tags should keep variant suffixes before the short SHA, matching the main build workflow:

```text
<release>_<short-ref-name><image-suffix>_<short-sha>
```

Use `_pwa`, `_spa`, and `_crm` for the corresponding mobile web build tags.

## Documentation Sync

When changing CI behavior, update all relevant agent/human documentation in the same change:

- `README.md`
- `AGENTS.md`
- `CLAUDE.md`
- `skills/nova-ci/SKILL.md`

Keep README as the canonical broad reference. Keep this skill concise and procedural.

## Validation

Run YAML parsing and whitespace checks:

```bash
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f); puts "OK #{f}" }' .github/workflows/*.yaml
git diff --check
```

Run `actionlint` if installed.

Review diffs for the files that define behavior:

```bash
git diff -- .github/workflows README.md AGENTS.md CLAUDE.md skills/nova-ci/SKILL.md
```

If product repository callers were touched, verify the user explicitly requested that and check those repositories separately.
