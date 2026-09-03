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
- `.github/actions/dast/action.yml` + `scan.sh` + `dast-common.sh`: the unauthenticated OWASP ZAP baseline (DAST); `dast-common.sh` holds the shared tally parse sourced by all three ZAP callers
- `.github/actions/dast-api/action.yml` + `scan.sh`: the authenticated ZAP API scan (`apiscan*`, `novatalks.core` only)
- `.github/workflows/ci-dast-live-baseline.yaml`: the `workflow_dispatch` live baseline against the real deployment, target allowlisted
- `scripts/test-sast-scan.sh`, `scripts/test-dast-scan.sh`, `scripts/test-dast-api-scan.sh`: offline scenario self-checks (`docker`, and for DAST `curl`, stubbed); extend when adding a decision branch
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

`scan*` is matched first and `unit-test` before the generic `test` check, so unit-only runs get `medium` while `int-test`/`full-test` get `large`. `base_ref` is read from `$GITHUB_EVENT_PATH` with `jq` (a tag push carries no branch in `GITHUB_REF`, and a new input would mean editing every product-repo caller); a missing or unreadable payload degrades to `small`, never to a bigger VM. **The `medium` branch exists for the DAST stack, not for faster builds** — `medium` is sized for postgres + redis + app + ZAP on one VM, the load `int-test` gets `large` for, so narrowing it to feature-branch builds would leave trunk builds (the ones that run DAST) on `small`; widening it to every core build puts ordinary builds into the medium pool where they contend with unit tests. The matrix applies only to real tag pushes (`refs/tags/*`); branch and PR refs always resolve to `small`, so a branch name containing `test` does not provision a large VM. A `full-test` tag runs both unit and integration tests sequentially on a single `large` runner (one tag push = one runner size; `integration-tests` needs `unit-tests`). Each size class has its own **max-2** concurrency cap; `medium` and `large` are independent pools, so unit-test and integration-test runs never contend — but trunk and `scan*` builds do share the `medium` pool with unit-test runs, which is the cost of the DAST sizing branch. All other repositories always resolve to `small`, regardless of tag.

The reuse check only picks GitHub-registered runners (online, idle, size priority ≥ required) whose backing Hetzner VM is in `running` status — registrations whose VM is deleting or gone (ghosts) are skipped, since a job queued on them would never start. Per-size counts are computed directly from the Hetzner API response (servers named `dev-00-gh-runner-*` with a matching `server_type` in `starting`, `initializing`, or `running` status), not from GitHub-registered runners, so in-flight VM creations are counted and offline "ghost" GitHub registrations (left over from failed creates) don't block new ones. A global `MAX_TOTAL_RUNNERS` guard (env-overridable, default `6`) counts every `dev-00-gh-runner-*` Hetzner server in any status across all sizes; once that total is reached, new triggers go to the wait queue regardless of per-size counts. The race-jitter sleep before these lookups is 0-9 seconds.

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

The switcher carries an **inline `sast-scan` job on `pull_request`** for the same eleven
repositories `secret-scan` covers. Builds are the evidence path, not the feedback path —
an ordinary pull request builds no image and so reaches no `sast-scan` in the build
workflow, which would leave a developer learning about a finding only after it is on
trunk. It checks out the merge commit, runs the same pinned `semgrep` action, and leaves
a job summary (counts **plus** the findings: severity, `path:line`, rule ID, message,
capped at 25 with a `Showing 25 of N` note) and the complete `.report` artifact. It is
advisory (only a broken scanner reds it) and has no notifier line. It is inline for the
same reason `secret-scan` is: `novatalks.core`'s PR route is a two-entry `build_target`
matrix, so a job in the build workflow would scan identical source twice per event.

`ci-build-ntk-on-push-tags-build.yaml` runs `sast-scan` (Semgrep, all standard build
repositories, **every build on any branch**) and `dast-scan` (OWASP ZAP baseline, trunk
and `scan*` builds only, three browser-surface repositories:
`novatalks.ui`, `novatalks.core`, `nova.botflow`; six headless ones were removed on
2026-09-01, tracked for the api-scan expansion — see below)
after `trivy-scan`, both delegating to a composite action. Three scanners, three
questions: Semgrep reads our source, Trivy reads the image, ZAP probes the running app.
Gitleaks covers secrets; ESLint answers none of them. See `docs/sast-dast.md`.

`ci-build-ntk-on-push-tags-widget-build.yaml` (`novatalks.chatwidget`'s workflow, not the
standard one) has its own `sast-scan` job mirroring the pattern above: same
every-non-`pull_request`-build gate, SHA-pinned checkout, `install-docker`, the same
`semgrep` composite action, and it upserts its report onto the release `build-widget`
already creates (`NTK.CHATWIDGET_<release>_<ref>_<sha>`) rather than a second one. It
needs no `PUBLISH_RELEASE` equivalent — `build-widget`'s `Create a Release` step is
itself ungated, so every build it follows already has a release to attach to. It has **no Trivy and
no DAST job** — that workflow zips `dist` and publishes it as a release asset, so there
is no container image for either to point at. Do not add one without inventing a target.
The notifier's `Compose SAST line` step is the same three-state shape as the main
workflow's (skipped / worded verdict / job died before `scan.sh` ran).

Preserve these behaviors:

- **A scanner that could not run is not a clean scan.** This is the spine of both
  actions. Semgrep exits 0 with an empty result set when no rules load, and a ZAP
  baseline against an app that crashed on boot produces the same empty report as a
  healthy one — so each scanner has to *prove* it ran.
- **Do not remove the Semgrep canary guard.** `.github/actions/semgrep/canary.yaml` is a
  one-rule config plus a generated file it must match, mounted next to the source. If
  that hit is absent the outcome is `error` (exit 2), never `clean`. `scan.sh` also
  fails closed on: no output file, exit > 1, unparseable JSON, and an empty
  `.paths.scanned`. Same class of trap as `gitleaks git --log-opts` exiting 0 on an
  unresolvable range.
- The canary hit is excluded from every bucket — `ERROR`, `WARNING`, `INFO` — **by rule
  ID, not by severity**. Severity used to be a caller input; excluding by check_id
  instead means the exclusion keeps working regardless of it.
- **`warn-only` governs findings only.** Findings warn and the build stays green; a
  broken scanner reds the job. Never collapse the two — Semgrep has no environmental
  reason to fail (no database, no running app), so its failure means broken tooling.
- **DAST has four outcomes and they must stay distinct**: `clean`, `findings`,
  `not-run`, `error`. `not-run` means the application never booted — `.env.example`
  drift, a missing migration, a changed port; none of them security events, and the
  image is already in GHCR. It is a **loud skip**: green build, `=== DAST: not run ===`
  in the report, a `WARNING` summary banner, and `⚠️ not run — <reason>` in the
  notification. Never silence it and never red it. ZAP itself failing (a non-zero exit
  that is not "warnings present", or no report file) is `error` and reds the job.
- **SAST gate:** `always() && github.event_name != 'pull_request' &&
  needs.build-image.result == 'success'` — **every build on any branch**. Semgrep reads
  the checkout, so it needs no running app, no database and no seeded stack, and a
  finding is cheapest before the branch merges. No Semgrep on `pull_request`:
  `build-image` is gated off there, so there is no build to read. The trunk/`scan*`
  narrowing was never about cost — it was about having a release to attach a report to
  — so it lives on as the job-level `PUBLISH_RELEASE` env
  (`IS_TRUNK == 'true' || startsWith(github.ref_name, 'scan')`), which gates the
  `Publish report release` step and picks the notifier's report URL (release asset when
  publishing, otherwise the run, where the artifact is). Do not let `sast-scan` create
  the release: `TRIVY.SCAN_*` only exists where `trivy-scan` made it, and
  `action-gh-release` would mint a `TRIVY.SCAN_*` git tag per feature build.
- **DAST gate:** the same, **plus** `(needs.build-image.outputs.IS_TRUNK == 'true' ||
  startsWith(github.ref_name, 'scan'))` and the three-repository list — it boots the
  built image next to its database, which is the cost that keeps it narrow.
  `build-image` resolves `IS_TRUNK` once as a job output because a job-level `if` cannot
  reach a step in another job. `trivy-scan` deliberately keeps its own `Resolve scan
  policy` step — two sources of truth for one predicate, accepted, and not to be
  "simplified" without reading spec D6.
- **Jobs are sequential** (`build-image → trivy-scan → sast-scan → dast-scan → notify`):
  both need `RELEASE`/`SHORT_REF_NAME`/`SHORT_SHA` from `build-image`, and parallel scans
  would only queue against the per-size cap of 2. Each carries `if: always() && …` so one
  failure swallows neither the next scan nor the notifier.
- **Three reports, one release.** Each job upserts its own `.report` onto the existing
  `TRIVY.SCAN_<release>_<ref><suffix>_<sha>` prerelease (`softprops/action-gh-release@v2`
  appends by tag; job needs `contents: write`), plus a run-scoped artifact and a job
  summary. The `TRIVY.SCAN_` prefix is **historical** and stays — renaming breaks the
  stable URLs documented in `docs/container-scanning.md`, and one release per scanner
  triples the walk for the quarterly evidence aggregation.
- **Pin both images by tag and digest**, never `latest`, for the reason the Gitleaks pin
  exists. Upgrade with `docker buildx imagetools inspect`.
- **The Semgrep canary and the `.errors[]` check are one guard in two halves.** The
  canary config is mounted from the action's own directory, so it fires even when every
  registry pack failed to fetch — canary proves the engine ran, empty `.errors[]` proves
  the configs resolved. Removing either re-opens "zero rules, reported clean".
- **Take the ZAP counts from the single tally line**, never from the `-w` report or from
  a per-rule `WARN-NEW:`/`FAIL-NEW:` line. `-w` writes the markdown "ZAP Scanning
  Report" and carries no count at all. One line, printed unconditionally at the end of
  any completed scan, carries all six: `FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 11
  WARN-INPROG: 0	INFO: 4	IGNORE: 7	PASS: 30`. Anchor on `^FAIL-NEW: <digits>` + a
  **literal tab byte** + `FAIL-INPROG: ` — the tally's *shape*, not the bare `FAIL-NEW: `
  prefix, which a per-rule FAIL-level line also starts with and would be matched
  instead, misreporting a real finding as a broken scanner. **Keep the pattern ANSI-C
  quoted (`$'…\t…'`), never a plain `'…\t…'` string:** BSD grep expands `\t` inside a
  pattern, GNU grep does not — it warns `stray \ before t` and matches a literal `t`.
  Every runner is GNU, so the plainly quoted form matches nothing in production, every
  completed scan reports a missing tally and reds the build, and a macOS harness run is
  the one place it passes. A missing or non-numeric tally is a scanner error, never a
  clean scan — the format moving under the pinned
  digest is not a zero. Keep the `tee` capture and `${PIPESTATUS[0]}` — ZAP's own exit
  status, unambiguously; plain `$?` only agrees because `pipefail` is set and would
  become `tee`'s status the moment that changed, or whenever `tee` itself fails — and
  the console log deleted on exit and never uploaded.
- **Keep `0|1|2` in the ZAP exit-code `case`.** Exit 1 is `FAIL`-level findings present
  and is a *finding*, not a broken scanner — `-I` gates exit 2 alone and does not
  suppress 1. Moving 1 into the error arm reds a trunk build the first time the triage
  register gains a `FAIL` entry.
- **`.github/actions/dast/zap-baseline.conf` is the triage register** — TAB-separated,
  at least three fields, levels `PASS`/`IGNORE`/`INFO`/`WARN`/`FAIL`/`OUTOFSCOPE`. The
  reason column is a **review-time obligation, not a parsed one** — an empty third field
  is accepted, because ZAP accepts it and this validator must never reject a register
  ZAP would load; do not add a check that enforces it. Ships with zero entries; adding
  one is a risk-acceptance decision, not a CI change. `scan.sh` validates line shape and
  level before anything boots and treats a malformed or missing register as a scanner
  error, but **cannot validate rule
  IDs** — a mistyped one is silently inert.
- **Rules come from the registry** (`p/typescript p/nodejs p/owasp-top-ten`), not
  vendored into `security/`. `ERROR` and `WARNING` are both counted and both listed in
  the report body — there is no `severity` input to narrow that. `INFO` is counted for
  the job summary only, kept out of the report body.
- **DAST baseline scope is three browser-surface repositories** — `novatalks.ui`
  (Vue SPA, port 8000, `/livez`), `novatalks.core` (dashboard, 3000, `/livez`,
  `needs-db`) and `nova.botflow` (Node-RED editor, 1880, `/`, `needs-db`) — gated on
  `github.event.repository.name` like the `postgres:17.9-trixie` and R2 exceptions. The
  ZAP baseline is a browser tool: it spiders HTML and checks header/cookie hygiene, so
  it only earns its keep where there is a browser surface to spider. A `Resolve DAST
  target` step (the same house pattern as `Resolve scan policy` in `trivy-scan`)
  resolves port, health path, `needs-db`, `needs-nats` and `extra-env` per repository
  via a `case` statement, one arm per repository with every value set explicitly; the
  default arm `::error::`s and exits non-zero rather than guessing. `nova.botflow` has no
  dedicated HTTP health route (its chart probes over `tcpSocket`), so its health path is
  `/` — the boot wait-loop accepts any HTTP response, 404 included, since it only tests
  that the process is listening; do not "fix" it to `/livez`. It brings up both redis and
  postgres since its storage backend is configurable. Adding a fourth needs an explicit
  request, a real browser surface, **and a boot probe first**: port and health path
  verified against the chart or Dockerfile, never guessed.
- **Six headless repositories were removed from the baseline on 2026-09-01**, tracked
  for the authenticated api-scan expansion: `nova.chatsconnector.{telegram,whatsapp,signal}-client-api`
  (all 3000, `/`, `needs-db`), `novatalks.dialer` (3000, `/livez`, `needs-db`,
  `needs-nats`), `novatalks.uspacy.connector` (3000, `/`, `needs-db`) and
  `novatalks.geoip-api` (3000, `/`, no db — an inference, not a verified fact). They are
  JSON APIs with no browser surface, so the baseline measured almost nothing on them.
  Their real coverage is the authenticated `api-scan` (OpenAPI-driven), live today for
  `novatalks.core` (`login`) and `nova.chatsconnector.telegram-client-api` (`db-token`);
  extending it to the remaining connectors that publish a spec (whatsapp, signal, dialer)
  is the tracked Phase 2, each verified against its own code, and `uspacy`/`geoip` have no
  OpenAPI spec. The verified ports/health/db facts above are kept for that work — they
  were established against the chart and Dockerfiles, not guessed. The `needs-nats` input
  still exists on `dast/action.yml` (and its NATS bring-up in `scan.sh`); no arm sets it
  `true` today because `novatalks.dialer` no longer reaches the baseline — but the
  api-scan work will need it: dialer reaches NestJS startup and dies with
  `ECONNREFUSED ::1:4222` without a NATS on 4222, and `scan.sh` brings up a bare,
  unconfigured `nats:2.10-alpine` (tag-pinned like `postgres:16`/`redis:8`) forcing
  `-e NATS_SERVERS=127.0.0.1:4222` after `--env-file`, since the failure was IPv6
  resolution of `localhost`, not a missing server.
- **`.env.example` is documentation and must not decide anything the scan depends on.**
  Four boot failures traced back to trusting it literally: a trailing `//` comment glued
  onto `NODE_ENV`, dotenv-style surrounding quotes that `docker --env-file` does not
  strip, an `APP_PORT` disagreeing with the Dockerfile, and a blank `KEY=` seeded as an
  empty string where the app had a perfectly good default. `scan.sh` therefore drops
  comment-bearing and empty-valued lines, strips one matching quote pair, never seeds
  `NODE_ENV`, and forces `PORT`/`APP_PORT` (and `NATS_SERVERS`, and `DATABASE_URL` when
  `needs-db`) after `--env-file`. It logs counts and names, never values.
- **`dast/action.yml`'s `extra-env` is the per-repository escape hatch** for template
  values no filter can fix — newline-separated `KEY=VALUE`, applied as `-e` flags after
  `--env-file` so each overrides the seeded value. The input still exists on the action,
  but no resolver arm uses it today — the three that did are all removed headless repos,
  knowledge kept for the api-scan expansion:
  `nova.chatsconnector.telegram-client-api` (four blanks its Joi schema rejects one per
  CI run), `nova.chatsconnector.signal-client-api` (an `S3_ENDPOINT` written as
  `https://<account-id>.…`, plus the blanks behind it), and `novatalks.dialer` (five
  `AWS_S3_*` — `multer-s3` throws `bucket is required` at boot and `FILE_DRIVER=s3` is
  the only driver it supports). Every value is a dummy and none is a credential; a real
  one belongs in a secret. `example.com` is the placeholder host — IANA-reserved, so it
  satisfies URL validators and is never contacted. Keep `TELEGRAM_API_HASH` as
  thirty-two *identical* hex characters: a realistic-looking hash trips Gitleaks'
  `generic-api-key` entropy heuristic and reds the required `secret-scan` check.
- Changing either `scan.sh` means adding a scenario to `scripts/test-sast-scan.sh` or
  `scripts/test-dast-scan.sh` in the same change. `validate.sh` also fails if any
  workflow runs `semgrep scan`/`semgrep ci`, a `docker run` of a Semgrep image,
  `zap-baseline.py`/`zap-full-scan.py`, or a third-party action for either. The ZAP
  half is narrower than the Semgrep half on purpose-not-yet-done: it does **not** match
  a bare `docker run ghcr.io/zaproxy/zaproxy`. Do not describe it as if it does.
- Be honest about reach in any documentation: the unauthenticated ZAP baseline finds
  header and cookie hygiene, not logic flaws. It is not a penetration test. The
  authenticated `apiscan*` scan adds real logged-in endpoints but stays passive — no
  IDOR, no privilege escalation, no business-logic flaw — and is not a pentest either.
- **API scan (`apiscan*`, opt-in — `novatalks.core` and the telegram connector today).**
  `dast-api/action.yml` + `scan.sh` boot the image on ephemeral postgres/redis, migrate and
  seed, acquire a token, and run `zap-api-scan.py -f openapi` against the app's own
  `/api-docs-json`. **Parameterised auth**: `auth-mode` is `login` (POST username/password,
  read the token from the response — core, `Authorization: Bearer`) or `db-token` (read the
  seeded token straight out of the DB with a caller-supplied `SELECT` — telegram, injected
  raw under `api_access_token`). The header, scheme prefix and token `SELECT` are per-repo
  inputs; the token is masked with `::add-mask::` whatever its source; an empty token
  (no login token, or the `SELECT` matched no row) is a loud `not-run`, never a scan without
  auth. **Safe mode `-S` is mandatory** — without it the tool active-scans, i.e. real writes
  against the seeded API; `scripts/test-dast-api-scan.sh` (42 checks) asserts `-S` and the
  mask. The seed admin password is `openssl rand`-generated per run and stored nowhere
  (`DEFAULT_ADMIN_USER` / `DEFAULT_USER_PASSWORD`). ZAP echoes the token-bearing replacer
  rule to its own stdout — a public repo's persisted step log — which is why the mask, plus
  the console file deleted on exit. Serving the spec can be conditional (`swagger-enable`:
  core needs `SWAGGER_ENABLE=true`, telegram serves it unconditionally and sets `false`); an
  empty spec is a loud `not-run`. Same four outcomes and tally parse as the baseline; its own
  triage register `dast-api/zap-api-scan.conf`, not the baseline's.
- **Each connector's auth model is read from its own code before its `Resolve api-scan
  target` arm is written.** Telegram's `db-token`/`api_access_token`/`tokens` shape is not
  assumed for the Sequelize connectors (whatsapp, signal) or dialer — the tracked Phase 2,
  each with its own token storage, header and seed path.
- **The tally parse lives once, in `dast/dast-common.sh`.** `zap_tally_parse` (anchor +
  numeric guard) is sourced by `dast`, `dast-api` and the live-baseline workflow. Never
  re-inline or copy it — the ANSI-C `\t` and the shape-not-prefix anchor are the exact
  divergent-copy hazard it exists to remove; a copy that rots reds only on GNU runners.
- **Live baseline (`ci-dast-live-baseline.yaml`, `workflow_dispatch`).** Scans the real
  deployment through Cloudflare — the edge surface the container scan cannot see (nginx
  serves the SPA with no CSP/HSTS on `/` while the engine's own routes carry them). The
  `target` input is validated against a **one-host allowlist** before scanning; adding a
  host is a deliberate edit, never runtime. SPA-200 caveat: the host returns 200 for every
  path, so duplicate header findings are duplication, not broader coverage.
  `setup-command` defaults to **empty**: both images so far migrate and seed from their
  own `ENTRYPOINT`, so the health poll is the completion signal. `novatalks.core` cannot
  do it any other way — its runtime stage installs `nodejs-24` and not npm. The app
  container also gets `DATABASE_URL` (Prisma reads that and nothing else) alongside the
  discrete `DATABASE_*` vars, both built from the values just given to postgres.
  The `-z` replacer values are wrapped in **literal single quotes**, and that is
  load-bearing: `zap-api-scan.py` runs the whole `-z` string through
  `shlex.split()` (`zap_common.py: add_zap_options`), so an unquoted
  `replacement=Bearer <token>` arrives as two arguments — ZAP sets the header to a
  bare `Bearer`, drops the token as a stray positional, and the scan runs
  unauthenticated while reporting a plausible result. `db-token` connectors hid it
  because their prefix is empty. The harness reproduces ZAP's own `shlex.split`;
  grepping the raw string passes either way.

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
git diff -- .github/workflows .github/actions security scripts docs README.md AGENTS.md CLAUDE.md .agents/skills/nova-ci/SKILL.md .claude/skills/nova-ci/SKILL.md
```

If product repository callers were touched, verify the user explicitly requested that and check those repositories separately.
