# CLAUDE.md

Guidance for Claude Code and Codex working in this repository.

`nova.ci` holds the shared GitHub Actions workflows for NovaTalks. Product repositories keep one thin caller workflow and call `novaitdevteam/nova.ci/.github/workflows/ci-build-trigger-switcher.yaml@main`. This repository is **public**.

## Start here

Human-facing documentation is canonical and lives in [`docs/`](docs/README.md). Read the page for the area you are touching **before** editing, and its rules file:

| Area | Page | Workflow it documents | Rules |
| --- | --- | --- | --- |
| Wiring a repo into CI | [`docs/getting-started/quick-start.md`](docs/getting-started/quick-start.md) | the caller workflow | [`dispatch-build-test`](.claude/rules/dispatch-build-test.md) |
| Dispatch and routing | [`docs/pipeline/routing.md`](docs/pipeline/routing.md) | [`ci-build-trigger-switcher.yaml`](.github/workflows/ci-build-trigger-switcher.yaml) | [`dispatch-build-test`](.claude/rules/dispatch-build-test.md) |
| Lint, unit gate, build, tags, cache | [`docs/pipeline/build-pipeline.md`](docs/pipeline/build-pipeline.md) | [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml) | [`dispatch-build-test`](.claude/rules/dispatch-build-test.md) |
| Unit and integration suites | [`docs/testing/tests.md`](docs/testing/tests.md) | [`ci-build-ntk-on-push-tags-run-test.yaml`](.github/workflows/ci-build-ntk-on-push-tags-run-test.yaml) | [`dispatch-build-test`](.claude/rules/dispatch-build-test.md) |
| Playwright E2E, lab and ephemeral stack | [`docs/testing/e2e.md`](docs/testing/e2e.md) | [`ci-e2e-tests-manual.yaml`](.github/workflows/ci-e2e-tests-manual.yaml) + [`e2e-stack/`](.github/actions/e2e-stack/) | [`e2e`](.claude/rules/e2e.md) |
| Secret detection | [`docs/security/secret-detection.md`](docs/security/secret-detection.md) | the `secret-scan` job + [`gitleaks/action.yml`](.github/actions/gitleaks/action.yml) | [`secret-detection`](.claude/rules/secret-detection.md) |
| Trivy scan and policy | [`docs/security/container-scanning.md`](docs/security/container-scanning.md) | the `trivy-scan` job | [`code-scanning`](.claude/rules/code-scanning.md) |
| SAST and DAST | [`docs/security/sast-dast.md`](docs/security/sast-dast.md) | the `sast-scan` / `dast-scan` jobs + [`semgrep/action.yml`](.github/actions/semgrep/action.yml), [`dast/action.yml`](.github/actions/dast/action.yml) | [`code-scanning`](.claude/rules/code-scanning.md) |
| Runner reuse, caps, lock, sizing | [`docs/pipeline/runners.md`](docs/pipeline/runners.md) | [`ci-build-create-runner.sh`](.github/workflows/ci-build-create-runner.sh) | [`runners`](.claude/rules/runners.md) |
| Notifier message and summary | [`docs/pipeline/notifications.md`](docs/pipeline/notifications.md) | the notifier jobs | [`runner-environment`](.claude/rules/runner-environment.md) |
| Harness and CI self-check | [`docs/reference/validation.md`](docs/reference/validation.md) | [`ci-self-validate.yaml`](.github/workflows/ci-self-validate.yaml) | — |
| Full inventory | [`docs/reference/reference.md`](docs/reference/reference.md) | everything | — |

Also read [`.agents/skills/nova-ci/SKILL.md`](.agents/skills/nova-ci/SKILL.md) before changing or reviewing CI behavior. [`README.md`](README.md) is a landing page — it links into `docs/` and must not restate the tables.

Use `rg` / `rg --files` for searches. Treat the worktree as potentially dirty: preserve staged, unstaged and unrelated edits.

## Invariants

The invariants live in [`.claude/rules/`](.claude/rules/), one file per area, each with the reasoning and the incident behind every rule. Breaking one is a regression even when the workflow still parses. Claude Code loads a rules file when it reads a file that file governs; **read it yourself** when you work from a diff, a log or a PR instead — the path trigger does not fire then. [`novatalks-core-exceptions.md`](.claude/rules/novatalks-core-exceptions.md) holds the rules gated on `novatalks.core`, [`docs-style.md`](.claude/rules/docs-style.md) the docs and diagram house style.

The ones that apply everywhere:

- Keep dispatch logic in `ci-build-trigger-switcher.yaml` and build-target interpretation in `ci-build-ntk-on-push-tags-build.yaml`.
- Do not edit product repository caller workflows unless the user explicitly asks.
- **A scanner that could not run is not a clean scan.** Every guard that proves a tool ran (the Gitleaks `rev-list` count, the Semgrep canary and `.errors[]`, the ZAP tally anchor, the OSV exit-code ladder) and every honest non-green state (`⏭️ n/a`, `⚠️ not run`) is load-bearing. Never remove or weaken one to make a run pass.
- Gitleaks, Semgrep, ZAP and OSV-Scanner run only through their `.github/actions/*` wrapper; `validate.sh` fails on a direct call.
- The check name `CI Build Trigger Switcher / secret-scan` is the required-status-check string. Never rename the job.
- Changing any `scan.sh` or `ci-build-create-runner.sh` means adding a scenario to the matching `scripts/test-*.sh` in the same change.
- Never add `continue-on-error` to `unit-test` or `integration-tests`.
- Never expand `${{ … }}` straight into `run:` — pass the value through step `env:` and use `$VAR`. A value laundered through `GITHUB_ENV` or a step output is as dangerous as the original, so sanitize anything ref- or PR-derived where it is first computed (as the build workflow does for `SHORT_REF_NAME`). `validate.sh`'s zizmor gate fails on a high-severity template injection and on any rise in the lower-severity count (`ZIZMOR_TEMPLATE_INJECTION_BACKLOG`); it cannot tell a sanitized `${{ env.X }}` from an unsanitized one — that is on review.

## Git workflow

- **nova.ci**: branch off `main`, open a PR, wait for `ci-self-validate` to go green, review (see Agent tooling), then merge. Never push to `main` directly.
- **Every other repository**: never commit or push to `development`/`dev`, `master` or `main`. Branch off `development` (or `dev`), or off `main`/`master` when there is none, and open a PR. Merging there is the repository owner's call unless the user asks.
- Commit only when asked.

## Credentials in the transcript

- Never print a credential value. Read `.env` redacted (`sed 's/=.*/=<redacted>/' .env`) or load it without printing (`set -a; . ./.env; set +a`), then use the variable — in a header, in step `env:` — but never `echo` it and never paste it into a file, a commit, an issue or a wiki page. `scripts/guard-secret-echo.sh` runs as a `PreToolUse` hook and blocks Bash commands that would dump a `.env`; run `./scripts/guard-secret-echo.sh --self-test` after changing it.
- That hook covers **one** accident. It cannot see an editor `@file` reference, which pastes the file into the conversation before any tool runs — that is how three live credentials from this repository's `.env` reached a transcript on 2026-08-31. It also cannot see a log line, an API response or a paste.
- When a value reaches the transcript anyway, say so **first**, before answering whatever was asked, and say that rotation is the only remedy. Deleting the line later fixes nothing: it was readable the moment it appeared, and this repository is **public**, so anything ever pushed stays fetchable after a force-push.
- Ask for secret **names**, not values. Values belong in GitHub Secrets.

## Agent tooling

Which skill or agent to reach for, and when. Launch with `make claude`: it exports `.env`, which `.mcp.json` needs for the Outline and Jira servers — a plain `claude` leaves both unconnected.

| Situation | Use |
| --- | --- |
| Any change to or review of workflows, routing, runners, tags, docs | skill `nova-ci` |
| A repository's entry in `dast/targets.sh`, or a DAST `not-run` / boot timeout | skill `dast-target-wiring` |
| A new feature or behaviour change | `superpowers:brainstorming` → `superpowers:writing-plans`; the spec and plan go to `docs/superpowers/specs/` and `plans/`, dated |
| Executing a plan of independent tasks | `superpowers:subagent-driven-development` (its reports land in `.superpowers/sdd/`, local and git-ignored) |
| A red test, a failed run, a loud skip | `superpowers:systematic-debugging`; reproduce on local Docker before spending CI runs |
| Changing any `scan.sh` or `ci-build-create-runner.sh` | `superpowers:test-driven-development` — the scenario in `scripts/test-*.sh` comes first |
| Writing the change | `ponytail` — smallest diff that holds, reuse what `.github/actions/` already has |
| Reviewing a diff | `/code-review` for correctness **and** `ponytail:ponytail-review` for over-engineering; `/security-review` when it touches a scanner, a secret or a token path |
| A whole-repo simplification pass | `ponytail:ponytail-audit`; `ponytail:ponytail-debt` lists every `ponytail:` shortcut left behind |
| Before saying "done", committing or opening a PR | `superpowers:verification-before-completion` — `./scripts/validate.sh` output, not an expectation |
| A new docs page or diagram | skill `beautify-github-readme` |
| Work finished and verified | agent `knowledge-capture` — `docs/` in English, Outline in Ukrainian |

**The invariants outrank ponytail.** Most guards in this repository look deletable and are not: the Semgrep canary and `.errors[]` check, the `git rev-list --count` guard, the tab-anchored ZAP tally, the `⏭️ n/a` states, the loud skips, the commented legacy route. Each exists because its absence produced a green run that measured nothing. A `ponytail-review` or `ponytail-audit` finding that would remove or weaken anything in `.claude/rules/` is dropped, not applied — and if the invariant itself looks wrong, raise it with the user rather than editing around it.

## Validation

```bash
./scripts/validate.sh   # or: make validate
```

Run it after any workflow, action, rule or documentation change. It parses every YAML, checks the skill mirror, resolves every docs link and asset, runs every `scripts/test-*.sh` harness offline, enforces the scanner-invocation and `GITHUB_WORKSPACE` guards, runs `zizmor` (high-severity template injection fails, the lower-severity count is a ratchet, the rest is an advisory backlog; required in CI, pinned by SHA-256, `uvx` fallback locally) and `actionlint` when installed (advisory; `STRICT_ACTIONLINT=1` enforces). What each check covers: [`docs/reference/validation.md`](docs/reference/validation.md). The same harness runs in CI on pull requests and pushes to `main`. A hook re-runs it after every edit under `.github/`.

Then review the diff:

```bash
git diff -- .github/workflows .github/actions security scripts docs README.md AGENTS.md CLAUDE.md .claude/rules .agents/skills .claude/skills
```

## Documentation sync

If you change repository lists, PR rules, routing or build semantics, update **in the same change**:

1. the relevant page under [`docs/`](docs/README.md) — and its diagram in that section's `assets/` if the diagram now lies
2. the matching [`.claude/rules/`](.claude/rules/) file, when an invariant changes (this file only when an everywhere-rule does)
3. [`AGENTS.md`](AGENTS.md), when the entry point changes
4. [`.agents/skills/nova-ci/SKILL.md`](.agents/skills/nova-ci/SKILL.md) **and** its mirror [`.claude/skills/nova-ci/SKILL.md`](.claude/skills/nova-ci/SKILL.md) — `validate.sh` fails if they diverge

Prefer small, targeted workflow edits over broad refactors. `README.md` only changes when the landing copy changes.
