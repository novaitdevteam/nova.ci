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
- Pull request events run lint only. The `build-image`, `trivy-scan`, and notifier jobs are gated on `github.event_name != 'pull_request'`, so PRs never build, scan, or publish an image.
- `novatalks.core` PRs lint a matrix of `build-engine` and `build-reporting`.
- After a successful `build-image`, the `trivy-scan` job scans the exact GHCR image that was built. It auto-runs when the source branch (`SHORT_REF_NAME`) is `main`, `master`, or `development`, and runs on demand when the trigger tag ref starts with `scan` (e.g. `scan` or `scan-NC2-1234`); otherwise it builds without scanning and logs the skip reason. The branch/repo/commit always come from push metadata, never from the tag name.
- The switcher routes `push` tags containing `build` or starting with `scan` (in standard build repositories) to the main build workflow.
- The notifier job `needs: [build-image, linter, trivy-scan]` and appends a Trivy line color-coded by worst severity (`🔴 CRITICAL found!` / `🟠 HIGH found` / `🟢 clean`, plus `❌ FAILED` under a fail mode or `⏭️ skipped`), with CRITICAL/HIGH counts and the report link, via a `Compose Trivy line` step that reads `trivy-scan` outputs. The job summary shows a matching colored alert banner (CAUTION/WARNING/NOTE). Under the default `warn-only` mode the build stays green; the styling is the signal.
- The scan uses `aquasecurity/trivy-action@v0.36.0` (pinned). It runs three passes (OS packages via `TRIVY_PKG_TYPES=os`, libraries via `TRIVY_PKG_TYPES=library`, and a JSON pass for counts), reusing the first install with `skip-setup-trivy: true`. The action manages the vulnerability and Java DBs, so there is no manual two-step DB download.
- The Trivy DB cache is `actions/cache` over `${{ github.workspace }}/.cache/trivy` with the action's own cache disabled (`cache: false`); the key embeds a 5-hour bucket (`trivy-db-5h-<floor(epoch/18000)>`) so the DB refreshes at least every ~5 hours.
- The scan output is a single `.report` file (`trivy-<repo>-<ref><suffix>-<sha>.report`) with `=== OS Vulnerabilities ===` and `=== Node.js Vulnerabilities ===` sections. It is uploaded as a workflow artifact and attached to a GitHub prerelease tagged `TRIVY.SCAN_<release>_<ref><suffix>_<sha>` (via `softprops/action-gh-release@v2`, requires `contents: write`), giving a stable download URL like the chat widget build. The job summary shows CRITICAL/HIGH counts and a link to the report.
- Scan policy is controlled by inputs `trivy_severity` (default `CRITICAL,HIGH`) and `trivy_mode`: `warn-only` (default, always succeed), `fail-on-critical` (fail when CRITICAL > 0), or `fail-on-high` (fail when CRITICAL or HIGH > 0). The image is built and pushed before the scan, so a failing scan signals red but does not unpublish the image.
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
- Keep pull request events lint-only. Do not let the `build-image`, `trivy-scan`, or notifier jobs run for `github.event_name == 'pull_request'`.
- Keep the Trivy scan tied to the built image: `trivy-scan` must `needs: [build-image]` and scan the exact GHCR tag the build produced. Keep auto-scan limited to `main`/`master`/`development` plus the `scan` trigger, and keep `warn-only` as the default policy.
- Keep the Trivy scan on `aquasecurity/trivy-action` (pinned) with the DB cache key bucketed to ~5 hours. Keep the report as a `.report` file with OS and Node.js sections, uploaded as an artifact and a release asset.
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

Run the validation harness after any workflow, action, or documentation change:

```bash
./scripts/validate.sh   # or: make validate
```

It parses every workflow and action YAML, runs `git diff --check`, verifies the
`.agents` ↔ `.claude` skill mirror, and runs `actionlint` when installed (advisory by
default — the repo has a pre-existing shellcheck/expression backlog; set
`STRICT_ACTIONLINT=1` to enforce). The same harness runs in CI via `ci-self-validate.yaml`
on pull requests and pushes to `main`.

Then check the final diff for consistency:

```bash
git diff -- .github/workflows .github/actions scripts README.md AGENTS.md CLAUDE.md .agents/skills/nova-ci/SKILL.md .claude/skills/nova-ci/SKILL.md
```
