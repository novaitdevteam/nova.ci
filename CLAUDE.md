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
| SAST and DAST | [`docs/sast-dast.md`](docs/sast-dast.md) | the `sast-scan` / `dast-scan` jobs + [`semgrep/action.yml`](.github/actions/semgrep/action.yml), [`dast/action.yml`](.github/actions/dast/action.yml) |
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
- **Do not re-add `!github.event.pull_request.draft` to the pull request build routes.** It was removed deliberately: the product callers' `pull_request:` has no `types:`, so `ready_for_review` never arrives, and a draft later marked ready got no lint and no unit tests at all — reported as `skipped`, not red. `novatalks.core#217` sat open for a month that way. Keep `ready_for_review` in the action lists: inert today, correct if a caller ever subscribes.
- Never introduce real tag deletion for PR builds. Tag deletion stays limited to tag-triggered builds with an empty `build_target`, and uses `actions/github-script@v8` (`git.deleteRef`), not a third-party action.

**Lint and tests**

- Keep unit tests advisory and sequential after lint (`needs: [linter]`, `if: !cancelled()`) — one build occupies one runner.
- Keep `build-image` ungated on lint and unit results.
- Do **not** add `continue-on-error` to `unit-test` or `integration-tests`. The job must still report red when tests fail.
- Keep the unit gate backward-compatible: repos without a test plan resolve to a no-op success, reported as `⏭️ n/a`, never `✅`.
- Keep `npm run test:unit` and `npm run test:integration` as the canonical scripts. Do not replace them with raw `npx jest` and hand-assembled flags.

**Secret detection**

- Keep the check name **`CI Build Trigger Switcher / secret-scan`** (and plain `secret-scan` in `ci-self-validate.yaml`). It is the required-status-check string; renaming the job silently un-protects every repository. That is why the job is inline in the switcher rather than behind another `uses:` — a third hop adds a third name segment.
- Keep both halves of the push gate: `github.ref_name == github.event.repository.default_branch` **and** the `main`/`master`/`development` list. The `default_branch` half is not a workaround for one odd repository — it makes the gate follow whatever a repo treats as its trunk, and removing it once every repo looks conventional silently un-covers the next one that does not. The failure mode is a scan that never runs.
- Keep the scan scoped to the commits an event **adds** (merge-base..head for PRs, `before..after` for pushes). Never make the blocking check read full history: legacy findings would fail every unrelated PR. Full history belongs to `scripts/gitleaks-baseline.sh`.
- Keep `scan.sh` **failing closed** — exit `2` on an unresolvable range, a missing SHA, an unreadable config, or an unexplained Gitleaks failure. Never fall back to Gitleaks' built-in rule set: that silently drops the central allowlist. (Opposite of the runner create lock, which fails open.)
- **Do not remove the `git rev-list --count` guard.** `gitleaks git --log-opts` exits **0** when git resolves nothing, so a bad or unfetched SHA otherwise reports a clean scan of zero commits.
- Keep Gitleaks pinned by version **and** SHA-256 in `gitleaks/action.yml`, never `latest`, and keep `scripts/test-secret-scan.sh` reading that pin so the tests exercise the version CI runs.
- Keep `--redact`. It blanks the value in stdout and in report files. Do not add a SARIF upload (needs `security-events: write`) or a report artifact — the redacted job summary already carries file, line, rule, commit and fingerprint.
- Keep `permissions: contents: read` on the job.
- `secret-scan-notify` is the compensating control for not being able to block a merge on the free plan. Keep the message composed in `scan.sh` (so the harness covers it), keep it free of credentials **and rule IDs**, and keep the three-way split between a PR leak, a protected-branch leak and a failed scan — an alert that cannot tell a leak from a broken gate is one people ignore. Keep the fallback message for a job that dies before `scan.sh` runs: silence looks like a clean run.
- `security/gitleaks/gitleaks.toml` carries exactly **one** path-scoped allowlist, and it is scoped by `targetRules = ["generic-api-key"]` to the heuristic entropy rule in test-fixture and docs paths. The ~170 provider-specific rules still apply there at full strength — that is the whole safety argument, and `scripts/test-secret-scan.sh` asserts it (a `github-pat` in a `.spec.ts` must still fail). **Never drop `targetRules` and never widen it to a second rule**: that turns it into the blanket `ignore tests/**` that hides real credentials. Any other exception goes through a `.gitleaksignore` fingerprint or an inline `gitleaks:allow`, per finding. There must be no input that disables the scanner.
- Changing `.github/actions/gitleaks/scan.sh` means adding a scenario to `scripts/test-secret-scan.sh` in the same change.
- Out of scope by decision on NC2-2742, do not add without an explicit request: `novatalks.tests`, `nova.chatsconnector.genesys.cloud.premium.wizard.engine` (deprecated), `nova.ai.marketplace`, `novatalks.charts`, `novatalks.grafana.connector` (the last three also have no caller workflow, so they never reach the switcher). Excluded repositories get **no** CI coverage; the baseline script is their only cover and must be run against them by hand.

**Scanning**

- `trivy-scan` must `needs: [build-image]` and scan the exact GHCR tag the build produced.
- Keep auto-scan limited to `main`/`master`/`development` plus the `scan*` trigger, and `warn-only` as the default policy.
- Keep the pinned `aquasecurity/trivy-action`, the ~5-hour DB cache bucket, and the `.report` file with OS and Node.js sections published as artifact and release asset.

**Code scanning (SAST/DAST)**

- `warn-only` governs **findings**. A scanner that could not run reds the job. Never collapse the two.
- A DAST application that fails to boot is a **loud skip** — green build, an explicit `⚠️ not run — <reason>` in the report, the job summary and the notification. Never silence it, never red it: boot failures come from `.env` drift or a missing migration, not from a vulnerability, and a job that is usually red for non-security reasons is a job people stop reading.
- Keep Semgrep and the ZAP image pinned by tag **and** digest, never `latest`. **Do not remove the Semgrep canary rule guard, and do not remove the `.errors[]` check next to it** — the two are halves of one guard. Semgrep reporting zero findings and Semgrep having loaded zero rules are indistinguishable without them, exactly like `gitleaks git --log-opts` exiting 0 on an unresolvable range. The canary alone is not enough: it is mounted from the action's own directory, so it fires even when every registry pack failed to fetch. The canary proves the engine ran, the empty `.errors[]` proves the configs resolved. The guard also asserts a non-empty `.paths.scanned`, and excludes the canary hit from every bucket — `ERROR`, `WARNING` and `INFO` — **by rule ID, not by severity**: severity used to be a caller input, and excluding by check_id instead means the exclusion keeps working regardless of it.
- Semgrep reports `ERROR` and `WARNING` as two counts and lists both. Do not reintroduce a single-severity filter: the old one was an exact equality that hid 12 `WARNING` findings on `novatalks.core` from the count *and* from the published report.
- Take the ZAP counts from the single tally line (anchored on `^FAIL-NEW: [0-9]+\tFAIL-INPROG: `, not the bare `^FAIL-NEW: ` prefix — a per-rule FAIL-level line starts with that same prefix and would be matched instead), never from the per-rule `WARN-NEW:` lines, and treat a missing or non-numeric tally as a scanner error. The line is printed unconditionally by any completed scan, so its absence means the scan did not finish.
- Keep `0|1|2` in the ZAP exit-code `case`. Exit **1** is `FAIL`-level findings and `-I` does not suppress it — `-I` gates exit 2 alone. Moving 1 back into the error arm reds a trunk build for a finding.
- `.github/actions/dast/zap-baseline.conf` is the triage register. Keep the reason column mandatory. Adding an entry is a risk-acceptance decision, not a CI change. A mistyped rule ID is silently inert; `scan.sh` validates line shape and levels only, and cannot validate IDs.
- Keep the scan scoped by the `build-image` `IS_TRUNK` output plus the `scan*` trigger, and off `pull_request` entirely — there is no release to attach a report to. `trivy-scan` keeps its own `Resolve scan policy` step on purpose; see spec D6 before "simplifying" two sources of truth into one.
- Keep all three reports on the **one** release the build already creates. The `TRIVY.SCAN_` tag prefix is historical and stays: renaming it breaks the stable URLs in `docs/container-scanning.md`, and one release per scanner triples the walk for the quarterly evidence aggregation.
- DAST is scoped to nine repositories: `novatalks.ui`, `novatalks.core`, `nova.botflow`, `nova.chatsconnector.telegram-client-api`, `nova.chatsconnector.whatsapp-client-api`, `nova.chatsconnector.signal-client-api`, `novatalks.dialer`, `novatalks.uspacy.connector`, `novatalks.geoip-api`. A repository is added only with an explicit request **and its port and health path verified against something authoritative** (the deployment chart, the Dockerfile) — never guessed. Port, health path, boot timeout and database needs are per-repository inputs, not constants to copy. Resolve them in the `Resolve DAST target` step's `case` statement in `dast-scan`, one arm per repository with every value set explicitly; the default arm fails loudly (`::error::` + non-zero exit) rather than falling back to a guess.
- The `medium` sizing branch for `novatalks.core` exists for the DAST stack, not for faster builds: `medium` is sized for postgres, redis, the application and ZAP on one VM — the load `int-test` already gets `large` for. Narrowing it to feature-branch builds would leave trunk builds, the ones that actually run DAST, on `small`; widening it to every core build puts ordinary builds into the medium pool, where they contend with unit tests.
- Changing either `scan.sh` means adding a scenario to `scripts/test-sast-scan.sh` or `scripts/test-dast-scan.sh` in the same change.
- No workflow may invoke Semgrep or ZAP directly; `validate.sh` fails on it, exactly as it does for Gitleaks.
- Be honest about reach in the docs: the unauthenticated ZAP baseline finds header and cookie hygiene, not logic flaws. Nobody should read the green check as a penetration test.

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
- Assets live in `assets/readme/`. **Every page under `docs/` opens with one** — a new page needs a new asset, and `validate.sh` fails without it. Use the `beautify-github-readme` skill.
- Static SVG is the default. A GIF only when motion explains something prose cannot; then keep the `.svg` source plus its `*-motion.json` spec next to the `.gif` and regenerate with that skill's `render_motion_gif.py` rather than hand-editing a GIF.
- Match the house style: `1200`-unit `viewBox`, the `ui-monospace,SFMono-Regular,Menlo,monospace` stack, the existing palette (it already carries GitHub's semantic `#3FB950` / `#F85149` / `#E3862B` — do not invent new ones), and a **minimum `font-size` of 18** SVG units.
- **Verify a new asset by rendering it, not by computing text widths.** `rsvg-convert -w 900` is GitHub's content width; also check `-w 360`. Text clipping against a panel edge does not show up in the arithmetic — it cost a rework on `secret-detection.svg`.

## Validation

Run the harness after any workflow, action or documentation change:

```bash
./scripts/validate.sh   # or: make validate
```

It parses every workflow and action YAML, runs `git diff --check`, verifies the `.agents` ↔ `.claude` skill mirror, runs the offline `ci-build-create-runner.sh` self-check (`scripts/test-create-runner.sh`, 22 checks, `curl` stubbed), runs the secret-scan self-check (`scripts/test-secret-scan.sh`, 24 checks against real git fixtures and the pinned Gitleaks binary), runs the SAST and DAST self-checks (`scripts/test-sast-scan.sh`, 29 checks, and `scripts/test-dast-scan.sh`, 110 checks, `docker` and `curl` stubbed), guards that no workflow invokes Gitleaks, Semgrep or ZAP directly, and runs `actionlint` when installed (advisory — the repo has a pre-existing backlog; set `STRICT_ACTIONLINT=1` to enforce). The same harness runs in CI on pull requests and pushes to `main`.

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
