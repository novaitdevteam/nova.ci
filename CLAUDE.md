# CLAUDE.md

## Project Context

`nova.ci` contains shared reusable GitHub Actions workflows for NovaTalks repositories. Product repositories typically use a local `.github/workflows/ci-build-trigger.yaml` workflow to handle events and runner setup, then call `novaitdevteam/nova.ci/.github/workflows/ci-build-trigger-switcher.yaml@main`.

Primary references:

- [`README.md`](README.md): human-facing CI documentation and routing table
- [`AGENTS.md`](AGENTS.md): shared instructions for Codex-compatible agents
- [`skills/nova-ci/SKILL.md`](skills/nova-ci/SKILL.md): portable CI maintenance skill usable by Claude as ordinary Markdown

## Working Instructions

- Read `README.md` and `skills/nova-ci/SKILL.md` before changing workflow behavior.
- Preserve unrelated staged and unstaged changes.
- Keep local product repository caller workflows unchanged unless explicitly asked.
- Update README, AGENTS.md, CLAUDE.md, and the skill when CI routing or build semantics change.
- Prefer small, targeted workflow edits over broad refactors.
- Keep notification jobs Docker-free. Telegram and Google Chat notifications should use `actions/github-script@v8` with Node.js `fetch`.

## Current CI Behavior

- `ci-build-trigger-switcher.yaml` is the central dispatcher.
- `ci-build-ntk-on-push-tags-build.yaml` is the main lint/build/publish workflow.
- `build_target` is an optional synthetic selector used primarily for PR builds.
- `novatalks.core` PRs run a matrix of `build-engine` and `build-reporting`.
- Other standard PR build repositories run with `build_target: build`.
- Real tag deletion must only happen for tag-triggered builds with an empty `build_target`.
- PR image tags use the PR head branch name, sanitized for Docker tag compatibility.
- Docker build jobs use `.github/actions/install-docker/action.yml` before Docker login, Buildx setup, or image builds.
- Mobile PWA/SPA/CRM image suffixes use `_pwa`, `_spa`, and `_crm` before the short SHA, matching the main build workflow suffix placement.
- Mobile APK workflows use Node.js `22.22.0`, install `zip`/`unzip`, resolve Android SDK paths dynamically, install required SDK packages with `sdkmanager`, write `src-capacitor/android/local.properties`, and locate `apksigner` under the resolved SDK.
- Notifier jobs use `action-cond` for success/failure text, then send Telegram and Google Chat messages through `actions/github-script@v8`.

## Validation

Run these checks after workflow changes:

```bash
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f); puts "OK #{f}" }' .github/workflows/*.yaml
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f); puts "OK #{f}" }' .github/actions/*/action.yml
git diff --check
```

Run `actionlint` when available.

Check the final diff for consistency:

```bash
git diff -- .github/workflows .github/actions README.md AGENTS.md CLAUDE.md skills/nova-ci/SKILL.md
```
