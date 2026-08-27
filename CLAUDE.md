# CLAUDE.md

Guidance for Claude Code and Codex working in this repository.

`nova.ci` holds the shared GitHub Actions workflows for NovaTalks. Product repositories keep one thin caller workflow and call `novaitdevteam/nova.ci/.github/workflows/ci-build-trigger-switcher.yaml@main`.

## Start here

Human-facing documentation is canonical and lives in [`docs/`](docs/README.md). Read the page for the area you are touching **before** editing:

| Area | Page | Workflow it documents |
| --- | --- | --- |
| Wiring a repo into CI | [`docs/quick-start.md`](docs/quick-start.md) | the caller workflow |
| Dispatch and routing | [`docs/routing.md`](docs/routing.md) | [`ci-build-trigger-switcher.yaml`](.github/workflows/ci-build-trigger-switcher.yaml) |
| Lint, unit gate, build, tags, cache | [`docs/build-pipeline.md`](docs/build-pipeline.md) | [`ci-build-ntk-on-push-tags-build.yaml`](.github/workflows/ci-build-ntk-on-push-tags-build.yaml) |
| Unit and integration suites | [`docs/tests.md`](docs/tests.md) | [`ci-build-ntk-on-push-tags-run-test.yaml`](.github/workflows/ci-build-ntk-on-push-tags-run-test.yaml) |
| Secret detection | [`docs/secret-detection.md`](docs/secret-detection.md) | the `secret-scan` job + [`gitleaks/action.yml`](.github/actions/gitleaks/action.yml) |
| Trivy scan and policy | [`docs/container-scanning.md`](docs/container-scanning.md) | the `trivy-scan` job |
| Runner reuse, caps, lock, sizing | [`docs/runners.md`](docs/runners.md) | [`ci-build-create-runner.sh`](.github/workflows/ci-build-create-runner.sh) |
| Notifier message and summary | [`docs/notifications.md`](docs/notifications.md) | the notifier jobs |
| Harness and CI self-check | [`docs/validation.md`](docs/validation.md) | [`ci-self-validate.yaml`](.github/workflows/ci-self-validate.yaml) |
| Full inventory | [`docs/reference.md`](docs/reference.md) | everything |

Also read [`.agents/skills/nova-ci/SKILL.md`](.agents/skills/nova-ci/SKILL.md) before changing or reviewing CI behavior. [`README.md`](README.md) is a landing page — it links into `docs/` and must not restate the tables.

Use `rg` / `rg --files` for searches. Treat the worktree as potentially dirty: preserve staged, unstaged and unrelated edits.

## Invariants

These are the rules `docs/` describes. Breaking one is a regression even when the workflow still parses.

**Dispatch**

- Keep dispatch logic centralized in `ci-build-trigger-switcher.yaml`, and build target interpretation centralized in `ci-build-ntk-on-push-tags-build.yaml`.
- Do not edit product repository caller workflows unless the user explicitly asks.
- Keep the legacy branch-push build route (`call-external-on-pull-request-merged`) **commented, not deleted**. A bare `contains(head_commit.message, 'build')` matched ordinary prose and built images from feature branches. If it is ever revived, gate it on an explicit marker (e.g. `[build]`) and/or a branch allowlist.

**Pull requests**

- Pull request events run lint and unit tests only. `build-image`, `trivy-scan` and the notifier stay gated on `github.event_name != 'pull_request'`.
- Never introduce real tag deletion for PR builds. Tag deletion stays limited to tag-triggered builds with an empty `build_target`, and uses `actions/github-script@v8` (`git.deleteRef`), not a third-party action.

**Lint and tests**

- Keep unit tests advisory and sequential after lint (`needs: [linter]`, `if: !cancelled()`) — one build occupies one runner.
- Keep `build-image` ungated on lint and unit results.
- Do **not** add `continue-on-error` to `unit-test` or `integration-tests`. The job must still report red when tests fail.
- Keep the unit gate backward-compatible: repos without a test plan resolve to a no-op success, reported as `⏭️ n/a`, never `✅`.
- Keep `npm run test:unit` and `npm run test:integration` as the canonical scripts. Do not replace them with raw `npx jest` and hand-assembled flags.

**Secret detection**

- Keep the check name **`CI Build Trigger Switcher / secret-scan`** (and plain `secret-scan` in `ci-self-validate.yaml`). It is the required-status-check string; renaming the job silently un-protects every repository. That is why the job is inline in the switcher rather than behind another `uses:` — a third hop adds a third name segment.
- Keep the scan scoped to the commits an event **adds** (merge-base..head for PRs, `before..after` for pushes). Never make the blocking check read full history: legacy findings would fail every unrelated PR. Full history belongs to `scripts/gitleaks-baseline.sh`.
- Keep `scan.sh` **failing closed** — exit `2` on an unresolvable range, a missing SHA, an unreadable config, or an unexplained Gitleaks failure. Never fall back to Gitleaks' built-in rule set: that silently drops the central allowlist. (Opposite of the runner create lock, which fails open.)
- **Do not remove the `git rev-list --count` guard.** `gitleaks git --log-opts` exits **0** when git resolves nothing, so a bad or unfetched SHA otherwise reports a clean scan of zero commits.
- Keep Gitleaks pinned by version **and** SHA-256 in `gitleaks/action.yml`, never `latest`, and keep `scripts/test-secret-scan.sh` reading that pin so the tests exercise the version CI runs.
- Keep `--redact`. It blanks the value in stdout and in report files. Do not add a SARIF upload (needs `security-events: write`) or a report artifact — the redacted job summary already carries file, line, rule, commit and fingerprint.
- Keep `permissions: contents: read` on the job.
- Keep `security/gitleaks/gitleaks.toml` free of **path** exclusions. Exceptions go through `.gitleaksignore` fingerprints or inline `gitleaks:allow`, per finding. There must be no input that disables the scanner.
- Changing `.github/actions/gitleaks/scan.sh` means adding a scenario to `scripts/test-secret-scan.sh` in the same change.
- The three repositories with no caller workflow (`nova.ai.marketplace`, `novatalks.charts`, `novatalks.grafana.connector`) cannot be covered from here. Do not add a caller to them unless the user asks.

**Scanning**

- `trivy-scan` must `needs: [build-image]` and scan the exact GHCR tag the build produced.
- Keep auto-scan limited to `main`/`master`/`development` plus the `scan*` trigger, and `warn-only` as the default policy.
- Keep the pinned `aquasecurity/trivy-action`, the ~5-hour DB cache bucket, and the `.report` file with OS and Node.js sections published as artifact and release asset.

**Runners**

- Keep the `small`/`medium`/`large` sizing matrix scoped to `novatalks.core`; every other repository always resolves to `small`.
- Keep the global `MAX_TOTAL_RUNNERS` cap and Hetzner-state-based per-size counting intact.
- Keep the create lock failing open: a lock-machinery error must warn and proceed, never block runner creation.

**Repository-scoped exceptions** — all gated on `github.event.repository.name == 'novatalks.core'`, none of them apply to other repositories without an explicit request:

- `postgres:17.9-trixie` as the integration Postgres image.
- The S3 (Cloudflare R2) file-storage step (`FILE_DRIVER=s3` + `AWS_S3_*`), with `R2_*` secrets routed through step `env:`, never inline `${{ secrets }}` in `run`.

**Runner environment**

- Keep Docker setup limited to jobs that need Docker, via [`install-docker/action.yml`](.github/actions/install-docker/action.yml).
- Keep notification jobs Docker-free and routed through [`notify/action.yml`](.github/actions/notify/action.yml): `actions/github-script@v8` with Node.js `fetch`. A workflow must not call the Telegram or Google Chat API directly — `validate.sh` fails on it.
- Keep mobile APK setup explicit — self-hosted images ship neither `zip`/`unzip` nor the Android build tools.

## Editing style

- Prefer small, targeted workflow edits over broad refactors.
- Changing `ci-build-create-runner.sh` means updating `scripts/test-create-runner.sh` in the same change. A decision branch without a scenario is untested.
- Keep file paths in documentation relative to the repository root (`../` from inside `docs/`).
- Assets live in `assets/readme/`. Animated pages keep the `.svg` source plus its `*-motion.json` spec next to the `.gif`; regenerate with the `beautify-github-readme` skill's `render_motion_gif.py` rather than hand-editing a GIF.

## Validation

Run the harness after any workflow, action or documentation change:

```bash
./scripts/validate.sh   # or: make validate
```

It parses every workflow and action YAML, runs `git diff --check`, verifies the `.agents` ↔ `.claude` skill mirror, runs the offline `ci-build-create-runner.sh` self-check (`scripts/test-create-runner.sh`, 16 scenarios, `curl` stubbed), runs the secret-scan self-check (`scripts/test-secret-scan.sh`, 24 assertions against real git fixtures and the pinned Gitleaks binary), guards that no workflow invokes Gitleaks directly, and runs `actionlint` when installed (advisory — the repo has a pre-existing backlog; set `STRICT_ACTIONLINT=1` to enforce). The same harness runs in CI on pull requests and pushes to `main`.

Then review the diff:

```bash
git diff -- .github/workflows .github/actions security scripts docs README.md AGENTS.md CLAUDE.md .agents/skills/nova-ci/SKILL.md .claude/skills/nova-ci/SKILL.md
```

## Documentation sync

If you change repository lists, PR rules, routing or build semantics, update **in the same change**:

1. the relevant page under [`docs/`](docs/README.md) — and its diagram in `assets/readme/` if the diagram now lies
2. this file, when an invariant changes
3. [`AGENTS.md`](AGENTS.md), when the entry point changes
4. [`.agents/skills/nova-ci/SKILL.md`](.agents/skills/nova-ci/SKILL.md) **and** its mirror [`.claude/skills/nova-ci/SKILL.md`](.claude/skills/nova-ci/SKILL.md) — `validate.sh` fails if they diverge

`README.md` only changes when the landing copy changes.
