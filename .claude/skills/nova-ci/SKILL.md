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

- `docs/`: canonical human-facing documentation, one page per topic (`docs/README.md` is the index)
- `README.md`: landing page only — value, quick start, links into `docs/`
- `AGENTS.md`: Codex-compatible agent instructions
- `CLAUDE.md`: Claude Code project instructions
- `.github/workflows/ci-build-trigger-switcher.yaml`: central dispatcher
- `.github/workflows/ci-build-ntk-on-push-tags-build.yaml`: main lint/build/publish workflow
- `.github/workflows/ci-build-ntk-on-push-tags-run-test.yaml`: test runner workflow (unit/integration/both)
- `.github/workflows/ci-build-create-runner.sh`: runner selection helper downloaded by product repo callers
- `.github/actions/action-cond/action.yml`: success/failure message selector used by notifier jobs
- `.github/actions/install-docker/action.yml`: Docker prerequisite helper for Docker build jobs
- `scripts/validate.sh`: validation harness (YAML, whitespace, skill mirror, create-runner self-check, actionlint); also `make validate`
- `scripts/test-create-runner.sh`: offline scenario self-check for `ci-build-create-runner.sh` (curl stubbed); extend it when adding a decision branch
- `.github/actions/gitleaks/action.yml` + `scan.sh`: the only place any workflow may invoke Gitleaks; `security/gitleaks/gitleaks.toml` is the central rule set and allowlist
- `scripts/test-secret-scan.sh`: offline scenario self-check for `scan.sh` (real git fixtures, pinned Gitleaks); extend it when adding a decision branch
- `.github/actions/semgrep/action.yml` + `scan.sh` + `canary.yaml`: the only place any workflow may invoke Semgrep (SAST)
- `.github/actions/dast/action.yml` + `scan.sh` + `dast-common.sh`: the unauthenticated OWASP ZAP scan (DAST) — `scan-mode` picks `zap-baseline.py` (default) or `zap-full-scan.py` (`full`, modern spider); `dast-common.sh` holds the shared tally parse sourced by all three ZAP callers
- `.github/actions/dast/targets.sh`: the one per-repository DAST table (port, health path, auth) — `dast_resolve_target <repo> <api|browser>`, sourced by the `Resolve DAST target` / `Resolve api-scan target` steps and every later consumer. Wiring a new repository into it is its own skill: `.agents/skills/dast-target-wiring/SKILL.md`
- `references/`: the depth behind this skill's "SAST and DAST Semantics" section — one file per scanner surface, read on demand rather than in full
- `.github/actions/dast-api/action.yml` + `scan.sh`: the authenticated ZAP API scan (`apiscan*`, `novatalks.core`, telegram, whatsapp, signal, dialer)
- `.github/workflows/ci-dast-live-baseline.yaml`: the `workflow_dispatch` live baseline against the real deployment, target allowlisted
- `.github/actions/deps-scan/action.yml` + `scan.sh`: dependency scan over the checkout's own lockfiles — Trivy fs (called directly in the switcher's `deps-scan` job, same as every other Trivy job here) and OSV-Scanner (`ghcr.io/google/osv-scanner`, tag- and digest-pinned; the only place any workflow may invoke it). Emits `clean` / `findings` / `no-manifests` / `error`. OSV-Scanner's exit code (not just its JSON) decides `error` — a network failure can leave a clean-looking JSON body behind; only `0`/`1`/`128` are acceptable exit codes.
- `scripts/test-sast-scan.sh`, `scripts/test-deps-scan.sh`, `scripts/test-dast-scan.sh`, `scripts/test-dast-api-scan.sh`, `scripts/test-dast-targets.sh`: offline scenario self-checks (`docker`, and for DAST `curl`, stubbed); extend when adding a decision branch
- `scripts/gitleaks-baseline.sh`: one-time full-history secret audit across product repositories; deliberately not a CI job
- `.github/actions/notify/action.yml`: the only place that talks to Telegram and Google Chat
- `.github/workflows/ci-self-validate.yaml`: CI that runs the harness on PRs and pushes to `main`

## Workflow Model

Product repositories usually keep a local `.github/workflows/ci-build-trigger.yaml` workflow. That caller handles events and runner setup, then calls:

```yaml
uses: novaitdevteam/nova.ci/.github/workflows/ci-build-trigger-switcher.yaml@main
secrets: inherit
```

Keep dispatch behavior in `ci-build-trigger-switcher.yaml`, not in product repository callers, unless the task explicitly asks to change caller behavior.

## Dispatch Rules To Preserve

- Push tags containing `build`, or starting with `scan`, in standard build repositories call the main build workflow.
- Branch pushes no longer trigger builds. The `call-external-on-pull-request-merged` job ("Call Builder On Merge PR") is commented out as legacy since 2026-08-12: its `contains(github.event.head_commit.message, 'build')` condition matched the substring anywhere in the full commit message, so prose like "Specs build partial module graphs" or "Verified: nest build" built and published images from feature branches. Keep the block commented rather than deleted; if it is revived, gate it on an explicit marker (e.g. `[build]`) and/or a branch allowlist, not a bare `build` substring.
- `pull_request` events on `opened`, `synchronize`, `reopened`, and `ready_for_review` call the main build workflow, but run lint and unit tests only: the `build-image`, `trivy-scan`, and notifier jobs are gated on `github.event_name != 'pull_request'`.
- **Drafts included — do not re-add `!github.event.pull_request.draft`.** The product callers' `pull_request:` carries no `types:`, so GitHub never sends `ready_for_review`; with the draft filter in place, a pull request opened as a draft and then marked ready got no lint and no unit tests at all, and reported `skipped` rather than red (`novatalks.core#217` sat open a month that way). Every head SHA arrives via `opened` or `synchronize`, so marking ready needs no event of its own. `ready_for_review` stays in the action lists: inert with today's callers, correct if one subscribes.
- `novatalks.core` PRs lint two targets: `build-engine` and `build-reporting`; unit tests run once on `build-engine` and are skipped on `build-reporting`.
- Other standard PR build repositories lint with `build_target: build`.
- Tags containing `int-test` → `ci-build-ntk-on-push-tags-run-test.yaml` with `test_mode: integration` (backward compatible).
- Tags containing `unit-test` → `ci-build-ntk-on-push-tags-run-test.yaml` with `test_mode: unit`.
- Tags containing `full-test` → `ci-build-ntk-on-push-tags-run-test.yaml` with `test_mode: both`.
- The three test tag substrings (`int-test`, `unit-test`, `full-test`) do not collide.
- Specialized tag workflows exist for docs, mobile APK/PWA/SPA/CRM, chat widget, botflow assets, and Playwright tests.
- The inline `secret-scan` job runs on `pull_request` (drafts included, like the build routes since drafts are linted too) and on branch pushes to the repository's `default_branch` or `main`/`master`/`development`, for the 11 repositories on the NC2-2742 list. Keep the `default_branch` half even when every repository looks conventional: it makes the gate follow whatever a repo treats as its trunk, and dropping it silently un-covers the next repo with an odd default (the failure mode is a scan that never runs, not one that errors). It is the one switcher job that is not a `uses:` dispatch — see Secret Detection Semantics.

Standard build repositories currently are:

- `novatalks.core`
- `novatalks.ui`
- `nova.botflow`
- `nova.chatsconnector.telegram-client-api`
- `novatalks.dialer`
- `nova.chatsconnector.genesys.cloud.premium.wizard.engine`
- `novatalks.geoip-api`
- `nova.chatsconnector.whatsapp-client-api`
- `nova.chatsconnector.signal-client-api`
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

Pull request events run lint and unit tests only. Keep the `build-image` and notifier jobs gated on `github.event_name != 'pull_request'` so PRs never build or publish an image.

PR builds must not delete tags. Keep tag deletion guarded by `github.ref_type == 'tag' && inputs.build_target == ''`.

Image tag ref labels should use `github.head_ref` for PRs and be sanitized for Docker compatibility.

Mobile PWA/SPA/CRM image tags should keep variant suffixes before the short SHA, matching the main build workflow:

```text
<release>_<short-ref-name><image-suffix>_<short-sha>
```

Use `_pwa`, `_spa`, and `_crm` for the corresponding mobile web build tags.

Mobile APK workflows should keep Node.js at `22.22.0` or newer because current Quasar/Icongenie tooling requires at least that Node version.

## Test Execution Semantics

### Unit Test Gate (ci-build-ntk-on-push-tags-build.yaml)

A `unit-test` job runs sequentially after `linter` (`needs: [linter]`, `if: !cancelled()`) on both PR and non-PR events, so a build uses one runner at a time instead of two. It runs even when lint failed. It is repo-aware via a "Resolve test plan" step. Currently only `novatalks.core` runs `npm run test:unit`; all other standard build repos resolve to a no-op success. To enable unit tests for a new repository, add a case in that step.

`build-image` has `needs: [linter, unit-test]`. The condition is `!cancelled() && github.event_name != 'pull_request'`. Both lint and unit tests are advisory: the build runs even if either fails. They are reported in the notifier and PR checks.

PR pipeline: `linter` then `unit-test` only. No image build. A unit test failure fails the PR check but blocks nothing downstream.

Do not add `continue-on-error` to the `unit-test` job — it must still report red on failure. Keep it backward-compatible: repos without a unit test plan must resolve to no-op success, not error.

The notifier includes a `Unit Tests Status:` line in the build message alongside the ESLinter status, with three states: `✅` (tests ran and passed), `❌` (job failed), and `⏭️ n/a (no unit tests configured)` when the "Resolve test plan" step produced no `unit_test_command`. Keep the `n/a` state: reporting `✅` for a repository that ran zero tests is misleading. The status is computed in the "End Unit Step" step from `job.status` plus the resolved `unit_test_command`; the job result stays `success` for a no-op run.

### Test Workflow Modes (ci-build-ntk-on-push-tags-run-test.yaml)

The test workflow accepts `test_mode: unit | integration | both` (default `integration`). The switcher derives `test_mode` from the tag substring and passes it as a workflow input.

| Tag substring | `test_mode` |
| --- | --- |
| `int-test` | `integration` |
| `unit-test` | `unit` |
| `full-test` | `both` |

The workflow also has a `workflow_dispatch` trigger with a `test_mode` choice input for manual runs.

Separate jobs: `unit-tests` (runs when mode is `unit` or `both`, no DB services) and `integration-tests` (runs when mode is `integration` or `both`, with redis:8 and a Postgres service). `integration-tests` has `needs: [unit-tests]` with a `!cancelled()` condition: in `both` mode the suites run sequentially on one runner (integration still runs if unit fails; suites report independently), and in `integration` mode the skipped `unit-tests` job does not block it. A `delete-tag` job deletes the trigger tag via `actions/github-script@v8` `git.deleteRef` (no third-party action).

The Postgres service image is repository-aware: `novatalks.core` uses the official `postgres:17.9-trixie` image (PG 17.9 on Debian trixie, matching the production major version), selected via `github.event.repository.name == 'novatalks.core'`; all other repositories (e.g. `novatalks.ui`) use `postgres:16`. The `POSTGRES_*` env vars, `pg_isready` health check, and `CREATE EXTENSION pgcrypto` step are unchanged across all repos.

File storage is repository-aware too: a `Configure S3 (Cloudflare R2) file storage` step, gated on `github.event.repository.name == 'novatalks.core'`, writes `FILE_DRIVER=s3` and the `AWS_S3_*` settings to `$GITHUB_ENV` before the integration run, from repo secrets `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET` (region `auto`, force path style). Keep it scoped to `novatalks.core` so other repos keep their default `FILE_DRIVER`, and keep the `R2_*` secrets routed via step `env:` (not inline `${{ secrets }}` in `run`). Secrets reach the reusable workflow through the switcher's `secrets: inherit`.

Both test jobs use npm scripts: `npm run test:unit` and `npm run test:integration` (the integration script already includes `--runInBand --forceExit --silent --verbose`). Do not replace them with raw `npx jest` flags in CI. No `continue-on-error` on either job; integration failures now fail the job (they were previously masked).

npm dependencies are cached via setup-node `cache: npm`.

Integration test sharding (jest `--shard` + matrix) is intentionally not enabled by default. Integration tests share database state and run with `--runInBand`. To parallelize, each shard would need its own postgres and Redis service plus `--shard=i/N`. Unit tests already parallelize via jest workers.

## Runner Tooling Semantics

Runner sizing is resolved in `ci-build-create-runner.sh` (downloaded from `nova.ci@main` by product-repo callers). For **`novatalks.core` only**, sizing is differentiated by tag substring:

| Tag | `base_ref` | `test_mode` | Runner size | Hetzner type | Why |
| --- | --- | --- | --- | --- | --- |
| `scan*` | any | — | `medium` | cx43 | runs DAST: postgres + redis + app + ZAP |
| `*build*` | `main`/`master`/`development` | — | `medium` | cx43 | trunk builds run DAST |
| `*build*` | anything else | — | `small` | cx33 | lint + build only |
| `*unit-test*` | — | `unit` | `medium` | cx43 | unit tests, no DB services |
| `*test*` | — | `integration` / `both` | `large` | cx53 | needs postgres + redis + app |
| anything else | — | — | `small` | cx33 | default |

`scan*` is matched first and `unit-test` before the generic `test` check, so unit-only runs get `medium` while `int-test`/`full-test` get `large`. `base_ref` is read from `$GITHUB_EVENT_PATH` with `jq` (a tag push carries no branch in `GITHUB_REF`, and a new input would mean editing every product-repo caller); a missing or unreadable payload degrades to `small`, never to a bigger VM. **The `medium` branch exists for the DAST stack, not for faster builds** — `medium` is sized for postgres + redis + app + ZAP on one VM, the load `int-test` gets `large` for, so narrowing it to feature-branch builds would leave trunk builds (the ones that run DAST) on `small`; widening it to every core build puts ordinary builds into the medium pool where they contend with unit tests. The matrix applies only to real tag pushes (`refs/tags/*`); branch and PR refs always resolve to `small`, so a branch name containing `test` does not provision a large VM. A `full-test` tag runs both unit and integration tests sequentially on a single `large` runner (one tag push = one runner size; `integration-tests` needs `unit-tests`). Per-size concurrency caps are **`medium` 4, `small` and `large` 2** (`MAX_MEDIUM_RUNNERS`/`MAX_PER_SIZE` override; `MAX_TOTAL_RUNNERS` 8 is their sum) — `medium` is the scan pool carrying two build targets' parallel scan fan-out, the other two have no fan-out to serve. `medium` and `large` are independent pools, so unit-test and integration-test runs never contend — but trunk and `scan*` builds do share the `medium` pool with unit-test runs, which is the cost of the DAST sizing branch. All other repositories always resolve to `small`, regardless of tag.

The reuse check only picks GitHub-registered runners (online, idle, size priority ≥ required) whose backing Hetzner VM is in `running` status — registrations whose VM is deleting or gone (ghosts) are skipped, since a job queued on them would never start. Per-size counts are computed directly from the Hetzner API response (servers named `dev-00-gh-runner-*` with a matching `server_type` in `starting`, `initializing`, or `running` status), not from GitHub-registered runners, so in-flight VM creations are counted and offline "ghost" GitHub registrations (left over from failed creates) don't block new ones. A global `MAX_TOTAL_RUNNERS` guard (env-overridable, default `8`, the sum of the per-size caps) counts every `dev-00-gh-runner-*` Hetzner server in any status across all sizes; once that total is reached, new triggers go to the wait queue regardless of per-size counts. The race-jitter sleep before these lookups is 0-9 seconds.

Before emitting `runner_need=true`, the script takes a short-TTL **create lock** to close the check-then-act race between concurrent triggers (the winner's VM is not yet visible to the per-size count while it is being created). The lock is a **Hetzner placement group** named `runner-create-lock-<size>` in the runner VMs' own Hetzner project: placement group names are unique per project, so the create is atomic (`uniqueness_error` = somebody else won), and it is written with the same `HCLOUD_TOKEN` every caller already passes to create VMs — org-wide scope, no extra credentials, no GitHub permissions (GitHub-ref lock variants all failed on token scope; SSH-key objects were rejected because their creation emails account notifications). The group's `epoch` label is the acquisition timestamp. A lock younger than `RUNNER_LOCK_TTL_SECONDS` (default 60s) sends the run to the wait queue with a `::notice::`; a stale lock (older, far-future, or unreadable epoch) is deleted and re-acquired; nobody releases the lock explicitly (TTL expiry hands the guard back to the per-size count). All lock-machinery failures fail **open** — create without the lock plus a `::warning::` — so an API problem can never block runner creation. Keep the lock in Hetzner, org-wide, and fail-open.

Docker build jobs should call `.github/actions/install-docker/action.yml` before Docker login, Buildx setup, or image builds. Keep Docker setup out of notifier jobs.

Mobile PWA/SPA/CRM builds use a named Docker context `builder`; create it idempotently with `docker context inspect builder >/dev/null 2>&1 || docker context create builder`.

Mobile APK workflows should not assume the self-hosted runner image has all Android tooling preinstalled. Preserve these setup behaviors:

- install `zip` and `unzip` before Gradle setup
- resolve Android SDK from `ANDROID_SDK_ROOT` or `ANDROID_HOME`, with common self-hosted runner fallbacks
- install `platform-tools`, `platforms;android-35`, and `build-tools;35.0.0` with `sdkmanager`
- write `src-capacitor/android/local.properties` with the resolved `sdk.dir`
- locate and use `apksigner` under the resolved SDK

## Secret Detection Semantics

Gitleaks runs as a `secret-scan` job — inline in `ci-build-trigger-switcher.yaml` for
product repositories, and in `ci-self-validate.yaml` for nova.ci itself (which has no
caller workflow). Both delegate to `.github/actions/gitleaks`.

Preserve these behaviors:

- **The check name is an API.** `CI Build Trigger Switcher / secret-scan` for product
  repositories, `secret-scan` for nova.ci. It is the required-status-check string, so
  renaming the job silently un-protects every repository. The job is inline rather than
  behind another `uses:` precisely because a third hop would add a third name segment.
- **Scan only the commits the event adds** — merge-base..head for pull requests,
  `before..after` for pushes. Never point the blocking check at full history: legacy
  findings would then fail every unrelated pull request. Full history is
  `scripts/gitleaks-baseline.sh`'s job.
- Use merge-base, not `base.sha`, for pull requests: the base branch moves while a PR
  is open, so `base.sha..head` would blame it for commits it never touched.
- **Fail closed.** `scan.sh` exits `2` on an unresolvable range, a missing SHA, an
  unreadable central config, or a Gitleaks failure with no finding in the log. It must
  never fall back to Gitleaks' built-in rule set — that silently drops the central
  allowlist. This is the opposite of the runner create lock, which fails open:
  blocking a build is cheaper than leaking a credential.
- **Keep the `git rev-list --count` guard.** `gitleaks git --log-opts` hands the range
  to `git log` and **exits 0 when git resolves nothing**, so a bad or unfetched SHA
  would otherwise report a clean scan of zero commits. `scan.sh` counts commits itself
  and fails if git disagrees.
- Keep `fetch-depth: 0` on the checkout — the base commit and the PR's own commits all
  have to be in the clone.
- Keep the version pinned by release tag **and** SHA-256 in `action.yml` (never
  `latest`: a moved tag or replaced asset would change what a mandatory check
  enforces). `test-secret-scan.sh` reads that pin out of `action.yml`, so bumping the
  version is automatically what gets tested.
- Keep `--redact`, which blanks the value in stdout and in report files. No SARIF
  upload (it would need `security-events: write`) and no report artifact: the redacted
  job summary already carries repository, file, line, rule ID, commit and fingerprint.
- Keep `permissions: contents: read`.
- `secret-scan-notify` (`needs: [secret-scan]`, runs only on `failure`) is the
  compensating control for the missing merge block. The message text is composed in
  `scan.sh`, not in the workflow, so the harness covers it. It must stay free of
  credentials **and rule IDs** (a chat group is wider than the repository), must keep
  the three-way split between a pull-request leak, a protected-branch leak and a failed
  scan, and must keep the workflow-level fallback message for a job that dies before
  `scan.sh` runs — silence looks like a clean run. Route it through
  `.github/actions/notify`, Docker-free, like every other notifier.
- The central config never needs fetching: using an action from another repository
  makes GitHub check out that whole repository next to it, so
  `security/gitleaks/gitleaks.toml` is on disk at the same nova.ci ref as the action.
  Do not add a second checkout or a `curl` for it.
- `security/gitleaks/gitleaks.toml` carries exactly one path-scoped allowlist, scoped
  by `targetRules = ["generic-api-key"]` to the heuristic entropy rule in test-fixture
  and docs paths. The ~170 provider-specific rules still apply there at full strength;
  `scripts/test-secret-scan.sh` asserts that a `github-pat` in a `.spec.ts` still
  fails. Never drop `targetRules` and never widen it to a second rule - that is the
  blanket `ignore tests/**` that hides real credentials. Any other exception is per
  finding: a `.gitleaksignore` fingerprint in the product repository, or an inline
  `gitleaks:allow` comment. There must be no workflow input that turns the scanner
  off.
- Deleting a secret in a follow-up commit is deliberately **not** remediation — it is
  still in the commits the PR would merge. The fix is rotate, then rewrite the branch.
- Changing `scan.sh` means adding a scenario to `scripts/test-secret-scan.sh` in the
  same change; `validate.sh` also fails if any workflow invokes Gitleaks directly.

Repositories covered (11, all reached through their existing caller workflow, no
product-repo change): `novatalks.core`, `novatalks.ui`, `novatalks.ui-lite`,
`nova.botflow`, `novatalks.dialer`, `novatalks.chatwidget`, `novatalks.geoip-api`,
`novatalks.uspacy.connector`, and the telegram, whatsapp and signal chatsconnectors.
`nova.ci` scans itself via `ci-self-validate.yaml`.

Out of scope by decision on NC2-2742, do not add without a request: `novatalks.tests`,
`nova.chatsconnector.genesys.cloud.premium.wizard.engine` (deprecated),
`nova.ai.marketplace`, `novatalks.charts`, `novatalks.grafana.connector`. The last
three also have no `ci-build-trigger.yaml`, so no event of theirs reaches the switcher.
Excluded repositories get no CI coverage at all - `scripts/gitleaks-baseline.sh` is
their only cover and has to be pointed at them by hand.

Enforcement is blocked by the GitHub plan, not by CI. The org is on **free**, where
rulesets are plan-gated for private repositories — verified: the same token gets
`403 Upgrade to GitHub Pro` on private `novatalks.core/rulesets` and `200 []` on public
`nova.ci/rulesets`. Classic branch protection is documented as Pro/Team-only for
private repos too, but that was not verified (needs org admin). What is lost is only
the hard merge block: the scan still runs, still reports red on the pull request, and
still fails on default-branch pushes. A notifier hookup is the compensating control if
the plan is not changing — deliberately not wired up, since it needs a channel
decision. nova.ci, being public, can enforce now.

## Credentials In The Transcript

- Never print a credential value. Read the secrets file redacted, or load it without
  printing (`set -a; . ./.env; set +a`), then use the variable — never `echo` it, never
  paste it into a file, commit, issue or wiki page. `scripts/guard-secret-echo.sh` runs
  as a `PreToolUse` hook and refuses Bash commands that would dump one; run
  `--self-test` after changing it, and keep both the block and the allow cases. It
  over-blocked twice before it worked — once on `open(` in Python, once on a `tail -1`
  in a different segment of the same command — and a security check that cries wolf
  teaches people to route around it.
- The hook covers one accident. It cannot see an editor `@file` reference, which pastes
  the contents in before any tool runs — that is how three live credentials reached a
  transcript on 2026-08-31 — nor a log line, an API response or a paste.
- When a value reaches the transcript, say so **first**, before answering whatever was
  asked, and say rotation is the only remedy. Deleting the line later fixes nothing, and
  `nova.ci` is public: anything ever pushed stays fetchable after a force-push.
- Ask for secret **names**, not values. Values belong in GitHub Secrets.

## Notification Semantics

Notifier jobs use `.github/actions/action-cond/action.yml` to select message text.

Telegram and Google Chat notifications should use `actions/github-script@v8` with Node.js `fetch`. Do not reintroduce Docker-based Telegram actions such as `appleboy/telegram-action`; notifier jobs should not require Docker.

In `ci-build-ntk-on-push-tags-build.yaml` the notifier `needs: [build-image, linter, unit-test, trivy-scan, sast-scan, dast-scan]` and a `Compose Trivy line` step builds a scan line color-coded by worst severity (`🔴 CRITICAL found!` / `🟠 HIGH found` / `🟢 clean`, plus `❌ FAILED` under a fail mode or `⏭️ skipped`), with CRITICAL/HIGH counts and the report link, from `trivy-scan` outputs, injected into the same message sent to Telegram and Google Chat. The message also includes a `Unit Tests Status:` line (✅ / ❌ / `⏭️ n/a (no unit tests configured)`) from the `unit-test` job output. `Compose SAST line` and `Compose DAST line` steps add one line per scanner, taken from the `MESSAGE` output each `scan.sh` composes (so the harnesses cover the wording), with a workflow-level fallback for a job that died before `scan.sh` ran — silence reads as a clean scan. Keep `⚠️ not run` distinct from `🟢 clean`. The job summary uses a matching colored alert banner (CAUTION/WARNING/NOTE).

## Trivy Image Scan Semantics

`ci-build-ntk-on-push-tags-build.yaml` has a `trivy-scan` job that `needs: [build-image]` and scans the exact GHCR image the build produced:

```text
ghcr.io/<owner>/<repo>:<release>_<short-ref-name><image-suffix>_<short-sha>
```

Preserve these behaviors:

- Keep the scan gated on `github.event_name != 'pull_request'` and `needs.build-image.result == 'success'`. PRs stay lint and unit tests only (no scan).
- The `Resolve scan policy` step auto-enables the scan when `SHORT_REF_NAME` is `main`, `master`, or `development`, and enables it on demand when the trigger tag ref starts with `scan` (`[[ "$REF_NAME" == scan* ]]`). Otherwise the image is built but not scanned. Branch/repo/commit come from push metadata, not the tag name.
- The switcher routes `push` tags containing `build` or starting with `scan` to the build workflow, so a `scan*` tag builds and scans a specific branch.
- On `novatalks.core` a `scan*` tag resolves to `build-engine` before the Dockerfile chain runs. A scan tag names a trigger, not a build target, and that repository has no `server.Dockerfile` to fall through to — the engine is its representative image, since the other components build from the same shared libraries. Other repositories and explicit `build_target` values are untouched.
- Scan with `aquasecurity/trivy-action@v0.36.0` (pinned). Run an OS pass (`TRIVY_PKG_TYPES=os`), a library pass (`TRIVY_PKG_TYPES=library`), and a JSON pass for counts; reuse the install with `skip-setup-trivy: true`. The action manages the vulnerability and Java DBs — do not reintroduce a manual `--download-db-only` / `--download-java-db-only` two-step.
- Cache the Trivy DB with `actions/cache` over `${{ github.workspace }}/.cache/trivy` (action cache disabled via `cache: false`); the key embeds a 5-hour bucket (`trivy-db-5h-<floor(epoch/18000)>`).
- Emit a single `.report` file (`trivy-<repo>-<ref><suffix>-<sha>.report`) with `=== OS Vulnerabilities ===` and `=== Node.js Vulnerabilities ===` sections. Upload it as a workflow artifact and attach it to a GitHub prerelease tagged `TRIVY.SCAN_<release>_<ref><suffix>_<sha>` (`softprops/action-gh-release@v2`, job needs `contents: write`). Put CRITICAL/HIGH counts and the report link in the job summary.
- `trivy_mode` policy: `warn-only` (default) always succeeds and only warns; `fail-on-critical` fails the job when CRITICAL > 0; `fail-on-high` fails when CRITICAL or HIGH > 0. The image is already built/pushed before the scan, so a failing scan signals red but does not unpublish it.

## SAST and DAST Semantics

Three scanners answer three questions: Semgrep (SAST) reads our source, Trivy reads the built
image, ZAP (DAST) probes the running app. Gitleaks covers secrets; ESLint answers none of
them. See `docs/sast-dast.md` for the full narrative and `references/` below for the
reasoning and evidence behind every rule in this section — **read the invariant here first,
its "why" lives one hop away, never dropped, only moved.**

Job map: the switcher runs inline `sast-scan` and `deps-scan` jobs on `pull_request` (Semgrep;
Trivy fs + OSV-Scanner) for the eleven `secret-scan` repositories, since a PR builds no image
and would otherwise get no SAST/dependency feedback until trunk. The build workflow runs
`sast-scan` on every build of every standard repository, and `dast-scan` (ZAP baseline/full)
plus opt-in `api-scan` (authenticated ZAP) only on trunk/`scan*` builds of the repositories
wired into `.github/actions/dast/targets.sh`. Two more `workflow_dispatch`-only workflows —
`ci-dast-live-baseline.yaml` and `ci-dast-pentest.yaml` — scan the real deployment or run an
**active** (real-write) scan. `references/sast-and-deps-scan.md` has the full job-by-job
architecture, including the widget workflow's own `sast-scan`.

Preserve these invariants — each is load-bearing; breaking one is a regression even if the
workflow still parses:

- **A scanner that could not run is not a clean scan.** This is the spine of every scanner
  action here. Semgrep exits 0 with an empty result set when no rules load; a ZAP scan against
  an app that crashed on boot produces the same empty report as a healthy one. Each scanner
  must *prove* it ran: Semgrep via the canary guard, ZAP via the tally-line format, OSV via its
  own exit code. See `references/sast-and-deps-scan.md` and `references/dast-baseline.md`.
- **`warn-only` governs findings only.** A scanner that could not run reds the job regardless
  of `warn-only`; only findings are advisory. Never collapse the two.
- **Do not remove the Semgrep canary guard or the `.errors[]` check next to it** — they are one
  guard in two halves (canary proves the engine ran, empty `.errors[]` proves the registry
  configs resolved), excluded from every severity bucket **by rule ID, not by severity**.
  `references/sast-and-deps-scan.md`.
- **DAST has four outcomes and they must stay distinct**: `clean`, `findings`, `not-run`
  (application never booted — a loud skip, green build, never silenced, never reds the job),
  `error` (ZAP itself failed). `references/dast-baseline.md`.
- **Take the ZAP counts from the single tally line, anchored on `^FAIL-NEW: <digits>` + a
  literal tab byte + `FAIL-INPROG: `, ANSI-C quoted (`$'…\t…'`).** A plainly quoted pattern
  matches nothing on GNU grep (every production runner) and reds every completed scan; only a
  macOS harness run passes. Never take counts from `-w`'s markdown report or a per-rule
  `WARN-NEW:`/`FAIL-NEW:` line. A missing or non-numeric tally is a scanner error, never a
  clean scan. `references/dast-baseline.md`.
- **Keep `0|1|2` in the ZAP exit-code `case`.** Exit 1 is `FAIL`-level findings, not a broken
  scanner; `-I` gates exit 2 alone. Moving 1 into the error arm reds a trunk build the first
  time the triage register gains a `FAIL` entry.
- **The triage registers (`zap-baseline.conf`, `zap-full-scan.conf`, `zap-api-scan.conf`) are
  never interchangeable**, and their reason column is a review-time obligation, not a parsed
  one — do not add a check that enforces it. `references/dast-baseline.md`.
- **`scan-mode` picks the whole ZAP invocation together** (script, spider flag, triage
  register) — never one of the three alone. An unrecognised mode is a scanner error, never a
  silent fallback. `references/dast-baseline.md`.
- **A `zap-context`'s `-n`/`-U` travel together, and a context file needs both a logged-in and
  a logged-out indicator regex.** A context that authenticates nobody while looking configured
  is worse than none — do not fill one in "to finish" an arm. `references/dast-baseline.md`.
- **`target: live` in `ci-dast-pentest.yaml` is browser-surface only.** There is no image to
  boot and no spec for `zap-api-scan.py` against a live host. `references/dast-baseline.md`
  and `references/dast-live-and-pentest.md`.
- **Every `DT_*` value `targets.sh` sets must be bridged to a consumer, not just declared** —
  a value set but never emitted or read produces a scan that looks configured and is not.
  `scripts/test-dast-targets.sh` asserts both directions. `references/dast-baseline.md`.
- **Neither DAST `scan.sh` infers the scanned repository from the runner's own repository** —
  `ci-dast-pentest.yaml` runs in `nova.ci`, not in the product repository, so a fallback to
  `${GITHUB_REPOSITORY##*/}` would be silently wrong there. `references/dast-baseline.md`.
- **The tally parse, the NATS bring-up, and the per-repository DAST table each live exactly
  once** — in `dast-common.sh` (`zap_tally_parse`, `dast_bring_up_nats`) and `targets.sh`
  (`dast_resolve_target`) respectively. Never re-inline or copy one into a workflow's own
  script or `case` — a copy that rots reds only on the runner flavor nobody tests locally.
  `references/dast-baseline.md`.
- **`.env.example` is documentation and must not decide anything the scan depends on.** Four
  real boot failures came from trusting it literally (a stray comment, unstripped quotes, a
  disagreeing port, a blank value overriding a real default); `scan.sh` filters and forces the
  values the scan itself depends on instead. `references/dast-baseline.md`.
- **The four auth modes for `api-scan` are `login`, `db-token`, `db-insert`, `env-token` (plus
  `none` for an unauthenticated target)** — each acquires or injects a token differently, and
  `env-token` is the one mode that must generate and mask its token *before* the container
  exists, since the app reads the variable once at its own startup.
  `references/dast-api-scan.md`.
- **`DEFAULT_ADMIN_USER` must be a syntactically valid email at a domain that can never be
  real** (`@example.invalid`, RFC 2606) — a syntactically invalid one fails a validator and
  blames the image for a boot timeout; a real domain risks a live mailbox.
  `references/dast-api-scan.md`.
- **Keep the `-z` replacer values wrapped in literal single quotes.** `zap-api-scan.py`
  `shlex.split()`s the whole `-z` string; an unquoted value drops the token as a stray
  positional and the scan runs unauthenticated while reporting a plausible result.
  `references/dast-api-scan.md` and `references/dast-live-and-pentest.md`.
- **Each connector's auth model is verified against its own code before its `targets.sh` arm
  is written — never assumed from a sibling**, even one that matches on schema (signal was
  expected to match whatsapp and was checked anyway: same schema, different health path and
  boot environment). `.agents/skills/dast-target-wiring/SKILL.md` and
  `references/dast-api-scan.md`.
- **`ci-dast-pentest.yaml` is the only workflow that runs either scanner in active mode**
  (real injection, traversal, `POST`/`PUT`/`DELETE`), is `workflow_dispatch` only with **no
  `schedule:`**, and its `repository` input is a `type: choice` with **no free-text URL input
  anywhere in the file** — the target is always derived from `targets.sh`, never typed in.
  `image_tag` is required for `target: ephemeral`, with no "most recent" lookup (the registry's
  tag list is not date-ordered) and no GHCR login step (every package is public).
  `references/dast-live-and-pentest.md`.
- **The pentest live target's allowlist is the whole safety mechanism** — one host, named in a
  `case` and nowhere else, compared to the typed `confirm` input **literally**, with the
  `id: confirm_live` structural (a missing/renamed `id` silently resolves to the empty string
  in GitHub Actions, not an error, producing `https://` as the scan target). **Every report,
  summary and notification for a live run must open with an unmistakable
  `⚠️ LIVE TARGET <host> — this scan performed real writes.` banner** — a report that could
  pass for an ephemeral run is exactly the failure this exists to prevent.
  `references/dast-live-and-pentest.md`.
- **`scripts/validate.sh`'s ZAP-direct-invocation guard is exempted for exactly two files**
  (`ci-dast-pentest.yaml`, `ci-dast-live-baseline.yaml`) and, for the pentest file, backed by a
  line-count assertion of **exactly one** direct ZAP call — a file-path exclusion cannot say
  "except these lines," the count is what keeps the ephemeral path honestly covered. Do not
  widen either exemption or replace the count assertion with a second blanket exclusion.
  `references/dast-live-and-pentest.md`.
- **Be honest about reach in any documentation.** The unauthenticated ZAP baseline finds
  header and cookie hygiene, not logic flaws, and is not a penetration test. The authenticated
  `api-scan` adds real logged-in endpoints but stays passive — no IDOR, no privilege
  escalation, no business-logic flaw — and is not a pentest either.
- **DAST baseline scope is three browser-surface repositories** (`novatalks.ui`,
  `novatalks.core`, `nova.botflow`); six headless repositories were removed from it on
  2026-09-01 in favor of the authenticated `api-scan`, and `novatalks.geoip-api` gets **no
  DAST at all** — no OpenAPI spec and no authentication, so an `api-scan` arm would be a green
  tick over zero operations. Adding a repository to any DAST surface needs an explicit request
  and values read from that repository's own code — see
  `.agents/skills/dast-target-wiring/SKILL.md`. `references/dast-baseline.md`.
- Changing any DAST or SAST `scan.sh` means adding a scenario to the matching
  `scripts/test-*.sh` in the same change.

Reference files, one per scanner surface:

- `references/sast-and-deps-scan.md` — Semgrep (inline PR job, build job, widget job) and
  `deps-scan` (Trivy fs + OSV-Scanner) job architecture, canary mechanics, gate details.
- `references/dast-baseline.md` — the unauthenticated ZAP baseline/full scan: outcomes, gates,
  tally-line format, exit ladder, triage registers, scan modes, repository scope,
  `.env.example` handling, the three "lives once" shared pieces.
- `references/dast-api-scan.md` — the authenticated `api-scan`: the four auth modes in full,
  the seed identity, the `-z` quoting bug, per-connector verification notes.
- `references/dast-live-and-pentest.md` — the two `workflow_dispatch`-only workflows: the live
  baseline against the real deployment, and the pentest workflow's ephemeral and live-target
  paths.

## Documentation Assets

Every page under `docs/` opens with a diagram from `assets/readme/`, and `validate.sh`
fails on a page without one. A new page therefore needs a new asset — build it with the
`beautify-github-readme` skill.

- Static SVG is the default. A GIF only where motion explains something prose cannot, and
  then the `.svg` source and its `*-motion.json` spec live next to the `.gif`; regenerate
  with that skill's `render_motion_gif.py` instead of hand-editing the GIF.
- Match the house style: `1200`-unit `viewBox`, the
  `ui-monospace,SFMono-Regular,Menlo,monospace` stack, the existing palette (GitHub's
  semantic `#3FB950` / `#F85149` / `#E3862B` are already in it — do not add new colours),
  and a minimum `font-size` of 18 SVG units.
- Verify by rendering, not by arithmetic: `rsvg-convert -w 900` is GitHub's content width,
  and `-w 360` is the mobile check. Text clipping against a panel edge is invisible in a
  width calculation and cost a rework on `secret-detection.svg`.
- Give the diagram a job. The one on the secret detection page exists to carry the single
  thing readers get wrong — that the scan reads the commits a change adds, not the working
  tree.

## Documentation Sync

When changing CI behavior, update all relevant agent/human documentation in the same change:

- the relevant page under `docs/` (`README.md` only if the landing copy changes)
- `AGENTS.md`
- `CLAUDE.md`
- `.agents/skills/nova-ci/SKILL.md` (and its mirror `.claude/skills/nova-ci/SKILL.md`)

Keep `docs/` as the canonical broad reference and `README.md` as a thin landing page. Keep this skill concise and procedural.

## Validation

Run the validation harness; it bundles every check (YAML parse of workflows and
actions, `git diff --check`, `.agents` ↔ `.claude` skill mirror sync, the
`ci-build-create-runner.sh`, Gitleaks, Semgrep and DAST (baseline and API) `scan.sh` scenario self-checks,
the scanner-invocation and notifier transport guards, and `actionlint` when installed — advisory by default given the repo's pre-existing
backlog; `STRICT_ACTIONLINT=1` enforces):

```bash
./scripts/validate.sh   # or: make validate
```

The same harness runs in CI via `ci-self-validate.yaml` on pull requests and pushes
to `main`. After it passes, review diffs for the files that define behavior:

```bash
git diff -- .github/workflows .github/actions security scripts docs README.md AGENTS.md CLAUDE.md .agents/skills .claude/skills
```

If product repository callers were touched, verify the user explicitly requested that and check those repositories separately.
