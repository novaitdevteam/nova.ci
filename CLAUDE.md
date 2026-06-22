# CLAUDE.md

This file provides guidance to Claude Code and Codex when working with code in this repository.

## Project Context

`nova.ci` contains shared reusable GitHub Actions workflows for NovaTalks repositories. Product repositories typically keep a thin local `.github/workflows/ci-build-trigger.yaml` workflow to handle events and runner setup, then call `novaitdevteam/nova.ci/.github/workflows/ci-build-trigger-switcher.yaml@main`.

Primary references:

- [`README.md`](README.md): human-facing CI documentation and routing table
- [`AGENTS.md`](AGENTS.md): Codex-compatible agent entry point (delegates here)
- [`.agents/skills/nova-ci/SKILL.md`](.agents/skills/nova-ci/SKILL.md): portable CI maintenance skill shared by Codex and Claude Code

## Start Here

- Read [`README.md`](README.md) for the current CI contract and routing table.
- Read [`.agents/skills/nova-ci/SKILL.md`](.agents/skills/nova-ci/SKILL.md) before changing or reviewing CI behavior.
- Use `rg` / `rg --files` for searches.
- Treat the worktree as potentially dirty. Preserve staged and unstaged changes and unrelated edits.

## CI Model

- [`ci-build-trigger-switcher.yaml`](.github/workflows/ci-build-trigger-switcher.yaml) is the central dispatcher.
- [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml) is the main lint/build/publish workflow.
- Product repository caller workflows should stay thin: event trigger, runner selection, and a `uses:` call into this repo.
- `build_target` is an optional synthetic selector used primarily for PR builds.
- Pull request events run lint only. The `build-image` and notifier jobs are gated on `github.event_name != 'pull_request'`, so PRs never build or publish an image.
- `novatalks.core` PRs lint a matrix of `build-engine` and `build-reporting`.
- Other standard PR build repositories lint with `build_target: build`.
- Real tag deletion must only happen for tag-triggered builds with an empty `build_target`. Tag deletion uses `actions/github-script@v8` (`git.deleteRef`), not a third-party Docker/Node-20 action.
- PR image tags (for non-PR builds that reuse a branch ref) use the head branch name, sanitized for Docker tag compatibility.
- Docker build jobs use [`install-docker/action.yml`](.github/actions/install-docker/action.yml) before Docker login, Buildx setup, or image builds.
- Mobile PWA/SPA/CRM image suffixes use `_pwa`, `_spa`, and `_crm` before the short SHA, matching the main build workflow suffix placement.
- Mobile APK workflows use Node.js `22.22.0`, install `zip`/`unzip`, resolve Android SDK paths dynamically, install required SDK packages with `sdkmanager`, write `src-capacitor/android/local.properties`, and locate `apksigner` under the resolved SDK.
- Notifier jobs use `action-cond` for success/failure text, then send Telegram and Google Chat messages through `actions/github-script@v8` and Node.js `fetch`.

## Editing Rules

- Keep dispatch logic centralized in `ci-build-trigger-switcher.yaml`.
- Keep build target interpretation centralized in `ci-build-ntk-on-push-tags-build.yaml`.
- Do not edit product repository caller workflows unless the user explicitly asks.
- Prefer small, targeted workflow edits over broad refactors.
- Keep pull request events lint-only. Do not let the `build-image` or notifier jobs run for `github.event_name == 'pull_request'`.
- Avoid introducing real tag deletion for PR builds. Tag deletion must stay limited to real tag-triggered builds.
- Keep Docker setup limited to jobs that actually need Docker, such as image build jobs.
- Keep notification jobs Docker-free. Telegram and Google Chat notifications should use `actions/github-script@v8` with Node.js `fetch`.
- Keep mobile APK runner setup explicit; self-hosted runner images may not have `zip`, `unzip`, Android Build Tools, or `apksigner` preinstalled.
- Keep file paths in documentation relative to the repository root.
- If changing repository lists, PR rules, or build semantics, update README, AGENTS.md, CLAUDE.md, and the skill together.

## Skills

Use these cross-LLM skills when relevant:

- [`.agents/skills/nova-ci/SKILL.md`](.agents/skills/nova-ci/SKILL.md) — Nova CI maintenance: switcher routing, PR `build_target` behavior, runner selection, Docker image tags, notifier semantics, and documentation sync.

Claude Code skill pointers mirror these under `.claude/skills/<skill>/SKILL.md`. Keep the canonical skill in `.agents/skills/` and its `.claude/` mirror in sync.

## Validation

Run these checks after workflow or documentation changes:

```bash
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f); puts "OK #{f}" }' .github/workflows/*.yaml
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f); puts "OK #{f}" }' .github/actions/*/action.yml
git diff --check
```

Run `actionlint` when available.

Check the final diff for consistency:

```bash
git diff -- .github/workflows .github/actions README.md AGENTS.md CLAUDE.md .agents/skills/nova-ci/SKILL.md .claude/skills/nova-ci/SKILL.md
```
