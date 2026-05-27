# AGENTS.md

## Purpose

This repository is `nova.ci`, the shared GitHub Actions workflow repository for NovaTalks projects. Product repositories usually keep a small local caller workflow and call reusable workflows from this repo with `uses: novaitdevteam/nova.ci/.github/workflows/...@main`.

Use this file as the high-level project guide for Codex-compatible agents. Claude Code has a parallel entry point in [`CLAUDE.md`](CLAUDE.md). The portable skill for both tools is [`skills/nova-ci/SKILL.md`](skills/nova-ci/SKILL.md).

## Start Here

- Read [`README.md`](README.md) for the current CI contract and routing table.
- Read [`skills/nova-ci/SKILL.md`](skills/nova-ci/SKILL.md) before changing or reviewing CI behavior.
- Use `rg` / `rg --files` for searches.
- Treat the worktree as potentially dirty. Preserve staged changes and unrelated edits.

## CI Model

- [`ci-build-trigger-switcher.yaml`](.github/workflows/ci-build-trigger-switcher.yaml) is the central dispatcher.
- [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml) is the main lint/build/publish workflow.
- Product repository caller workflows should stay thin: event trigger, runner selection, and `uses:` call into this repo.
- PR builds do not create Git tags. The switcher passes synthetic `build_target` values into the reusable build workflow.
- `novatalks.core` PRs run `build-engine` and `build-reporting`.
- Other standard PR build repositories run with `build_target: build`.

## Editing Rules

- Keep dispatch logic centralized in `ci-build-trigger-switcher.yaml`.
- Keep build target interpretation centralized in `ci-build-ntk-on-push-tags-build.yaml`.
- Do not edit product repository caller workflows unless the user explicitly asks.
- If changing repository lists or PR rules, update README, AGENTS.md, CLAUDE.md, and `skills/nova-ci/SKILL.md` together.
- Avoid introducing real tag deletion for PR builds. Tag deletion must stay limited to real tag-triggered builds.
- Keep file paths in documentation relative to the repository root.

## Validation

Use these checks after workflow or documentation changes:

```bash
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f); puts "OK #{f}" }' .github/workflows/*.yaml
git diff --check
```

Run `actionlint` if it is installed:

```bash
actionlint
```

For behavior changes, inspect:

```bash
git diff -- .github/workflows README.md AGENTS.md CLAUDE.md skills/nova-ci/SKILL.md
```
