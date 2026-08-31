# SAST and DAST Scanning: Spec

**Ticket:** none yet — to be filed once scope is settled (agreed 2026-08-28)
**Status:** designed — implementation plan pending
**Date:** 2026-08-28

## Problem

An information-security risk item requires that Static and Dynamic Code Analysis
(SAST/DAST) results be signed off quarterly by the IS Manager and the Lead Dev, with a
backlog for closing findings. The technical half of that requirement is not met today:

- **SAST** — the pipeline runs ESLint (code quality, not security) and Gitleaks (secrets).
  Neither is static security analysis of our own code.
- **DAST** — nothing. No tool ever sends a request to a running instance.
- **Evidence** — Trivy produces one `.report` per build as a release asset, but it covers
  the container image (OS packages and libraries), not our source and not the running app.

GitHub's own code scanning was ruled out first: CodeQL is free only for public
repositories, and every `novaitdevteam` repository is private, so it would require GitHub
Advanced Security. SonarQube Community Build was ruled out second: branch analysis is a
paid-edition feature, so the free edition cannot cover `main`, `master` and `development`
— which is exactly the coverage being asked for.

The signature and the regulation are a process control and are out of scope here. What is
in scope is producing the evidence that control signs: per-build, per-repository security
reports that a quarterly aggregation can later walk.

## Scope

**In:** Semgrep OSS as SAST across all standard build repositories, `novatalks.core` included; OWASP ZAP baseline as
DAST on `novatalks.ui` and `novatalks.core`; separate report artifacts on the existing
build release; scanner status lines in the notifier; a runner-size branch for the DAST
stack; test harnesses for both scanners.

**Sequencing:** SAST ships first and DAST second. A1 below gates the DAST half, and the two share no code, so a blocked boot probe must not hold up working SAST coverage.

**Out, by decision:** consolidating the `trivy-scan` gate onto the new `IS_TRUNK` output
(D6); Semgrep on `pull_request` (D13); vendoring Semgrep rules into `security/semgrep/`
(D5); the quarterly aggregation script; DAST on the other eight build repositories.

## Decisions

Each row is a decision that could reasonably have gone the other way.

| # | Decision | Why, and what it rules out |
| --- | --- | --- |
| D1 | **Two composite actions** (`.github/actions/semgrep/`, `.github/actions/dast/`), each with its own `scan.sh`, rather than steps inlined into `trivy-scan` | Repeats the architecture the repo already chose for Gitleaks, and follows NC2-2742's D6: logic that cannot be exercised locally does not belong in a security gate. Semgrep parses JSON and counts by severity; DAST runs a wait-loop, a cleanup and a three-way status — precisely the code a harness must cover. Rules out the shortest diff. |
| D2 | **Sequential jobs**: `build-image → trivy-scan → sast-scan → dast-scan → notify` | Both new jobs need `SHORT_REF_NAME`/`RELEASE`/`SHORT_SHA` from `build-image` to address the release, so neither can start earlier. Running the three scans in parallel would only queue against the per-size cap of 2 runners with no wall-clock gain. Each job carries `if: always() && …` so one failure does not swallow the rest or the notifier. |
| D3 | **SAST gate = the Trivy gate**: source branch in `main`/`master`/`development` ("trunk" throughout this document), or a ref starting with `scan` | Not a cost decision — Semgrep is cheap. A report is only useful where there is a release to attach it to, and PR events never build one. |
| D4 | **DAST scoped to `novatalks.ui` and `novatalks.core`** via `github.event.repository.name` | The same repository-scoped-exception pattern already used for `postgres:17.9-trixie` and R2 storage. Two poles of difficulty — static assets and a backend needing postgres, redis and a schema — so the remaining eight roll out by copy rather than discovery. Rules out writing eight boot configs blind, several of which would silently scan an error page. |
| D5 | **Semgrep rules from the registry (`p/typescript`, `p/nodejs`, `p/owasp-top-ten`), not vendored**, plus a guard asserting rules actually loaded | Vendoring mirrors `security/gitleaks/gitleaks.toml` but means thousands of files against one config. The real risk is not the registry being unavailable, it is Semgrep running with zero rules and reporting clean — the same trap as `gitleaks git --log-opts` exiting 0 on an unresolvable range. The guard closes that for far less. If the registry ever does fail, it surfaces as a red job, not as silence. |
| D6 | **`build-image` gains an `IS_TRUNK` output** consumed by the two new jobs; `trivy-scan` keeps its own `Resolve scan policy` step | Job-level `if` cannot reach a step inside another job, and re-expressing the branch list twice more in YAML is worse. Two sources of truth for one predicate is a real wart, accepted deliberately: consolidating would change the behaviour of the only scanner currently working, for cosmetics. |
| D7 | **`ERROR` severity only** on first rollout | The first run over an established codebase at `WARNING` yields a volume nobody triages, and an untriaged backlog is the exact failure this work exists to fix. `WARNING` is added once the real count is known. |
| D8 | **Findings warn; a broken scanner reds the job** | `warn-only`, agreed for policy, governs *findings*. A scanner that could not run is a different event. CLAUDE.md already states this for `secret-scan-notify`: an alert that cannot tell a leak from a broken gate is one people ignore. SAST has no environmental reason to fail — no database, no application — so its failure means broken tooling. |
| D9 | **A DAST application that fails to boot is a loud skip, not a red build and not silence** | Boot failures come from `.env.example` drift, a missing migration on an empty database or a changed port — none of them security events, and the build is already green with the image already in GHCR. The report and the notification carry a distinct `⚠️ not run — <reason>` status, separate from `clean`. Deliberately the opposite of D8's broken-scanner case: ZAP itself failing is still red. |
| D10 | **Three report files on one release**, reusing the existing `TRIVY.SCAN_<release>_<ref><suffix>_<sha>` tag | `softprops/action-gh-release@v2` upserts by tag, so each job publishes its own file independently. The `TRIVY.SCAN_` prefix becomes historical — renaming to `SCAN_` would break the stable URLs documented in `docs/container-scanning.md` for cosmetic gain. Rules out one release per scanner: three prereleases per trunk build is noise, and it triples the walk for the eventual quarterly aggregation. |
| D11 | **Runner size: on `novatalks.core`, `medium` (cx43) whenever DAST will run** — a `build` tag whose `base_ref` is a trunk branch, or any `scan*` tag | The DAST stack is postgres + redis + the application + ZAP — the same load that already earns `large` for `int-test`. `medium` is the agreed starting point. The condition mirrors the DAST gate exactly rather than approximating it: a `scan*` tag triggers DAST on any branch and currently falls through the sizing matrix to `small`. Scoped by `base_ref` so feature-branch builds stay `small` and do not migrate into the medium pool, where they would begin contending with unit-test runs; the pools are deliberately disjoint today. |
| D12 | **`base_ref` read from `$GITHUB_EVENT_PATH` with `jq` inside `ci-build-create-runner.sh`** | `jq` is already a dependency of that script, and reading the event payload keeps the change inside `nova.ci`. Passing it as a new input would mean editing every product-repository caller — which CLAUDE.md forbids without an explicit request. |
| D13 | **No Semgrep job on `pull_request`** | A PR would give the tighter feedback loop, but `build-image` is gated off for PRs, so there is no release and therefore no stable report URL — and the evidence pack is the point of this work. Revisit as a second, summary-only run once the release path is proven. |
| D14 | **A `validate.sh` guard forbidding direct `semgrep` / ZAP invocation in workflows** | Modelled on the existing Gitleaks invocation guard. Without it the first inline `docker run semgrep` step bypasses the pin, the rule-load guard and the harness at once. |

## Verified behaviours

Established by reading this repository, not assumed.

| Claim | Result |
| --- | --- |
| Builds are triggered by tag pushes; the branch in the image tag comes from the event payload | ✅ `ci-build-ntk-on-push-tags-build.yaml:346` — `short_ref_name="${BASE_REF#refs/heads/}"` where `BASE_REF` is `github.event.base_ref` |
| Branch pushes no longer build | ✅ `call-external-on-pull-request-merged` is commented out as legacy |
| `ci-build-create-runner.sh` sees only `GITHUB_REPOSITORY` and `GITHUB_REF` | ✅ lines 6-16; `base_ref` is not currently read, hence D12 |
| A `build` tag on `novatalks.core` currently resolves to `small` | ✅ lines 30-33 |
| One tag push sizes one runner for the whole run | ✅ `docs/runners.md`, sizing section |
| Per-size runner cap is 2, global cap defaults to 6 | ✅ `ci-build-create-runner.sh:22`, `docs/runners.md` |
| Jobs are not guaranteed the same runner, so container state does not survive between them | ✅ implied by the pooled reuse model; `integration-tests` performs bring-up, run and cleanup inside a single job for this reason |
| A reusable bring-up pattern for postgres + redis already exists | ✅ `ci-build-ntk-on-push-tags-run-test.yaml:173-193`, with `.env.example` handling at 201-205, `pgcrypto` at 215-219 and cleanup at 294 |
| `trivy-scan` needs a successful `build-image` and never runs on PRs | ✅ `ci-build-ntk-on-push-tags-build.yaml:545-546` |
| Every page under `docs/` must open with an `assets/readme/` diagram | ✅ enforced by `scripts/validate.sh:62-70` |
| Workflows may not invoke Gitleaks directly | ✅ enforced by `scripts/validate.sh:142`; D14 mirrors it |

## Assumptions to establish during implementation

These are not placeholders — each has a decided fallback, but the plan must settle them
empirically before the dependent step is written.

| # | Assumption | How it is settled, and the fallback |
| --- | --- | --- |
| A1 | `novatalks.core` boots against an empty postgres, i.e. the image runs migrations at start | First implementation step, before any DAST code. If it does not, DAST for `core` is limited to the loud-skip path until a migration step exists, and `novatalks.ui` ships alone. |
| A2 | `novatalks.ui` serves HTTP from its image without dependencies | Assumed from the Vue lint target at `ci-build-ntk-on-push-tags-build.yaml:85`; **not confirmed against the runtime image**. Verified by the same boot probe as A1. |
| A3 | `cx43` is sufficient for postgres + redis + application + ZAP | Measured on the first real `core` run. Fallback is `large`, which is the documented size for the same stack under `int-test`. |
| A4 | Semgrep exits 0 and reports clean when no rules load | The premise of D5's guard. Confirmed in the harness fixture; if Semgrep already fails loudly, the guard stays as cheap insurance. |
| A5 | `softprops/action-gh-release@v2` appends assets to an existing tag rather than replacing them | Premise of D10. If it replaces, fall back to one release per scanner as described in D10's rejected alternative. |

## Impact surface

**New:** `.github/actions/semgrep/{action.yml,scan.sh}`, `.github/actions/dast/{action.yml,scan.sh}`, `scripts/test-sast-scan.sh`, `scripts/test-dast-scan.sh`, `docs/sast-dast.md`, `assets/readme/sast-dast.svg`.

**Changed:** `ci-build-ntk-on-push-tags-build.yaml` (two jobs, `IS_TRUNK` output, notifier lines), `ci-build-create-runner.sh` (D11/D12 sizing branch), `scripts/test-create-runner.sh` (three scenarios), `scripts/validate.sh` (two harnesses, one guard), `docs/{container-scanning,runners,notifications,validation,reference,README}.md`, `CLAUDE.md`, and both mirrors of `nova-ci/SKILL.md`.

**Unchanged, deliberately:** product-repository caller workflows, `AGENTS.md`, the `secret-scan` check name, the `trivy-scan` gate.
