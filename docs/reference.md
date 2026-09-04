# Reference

<p align="center">
  <img src="../assets/readme/reference.svg" width="100%" alt="one dispatcher workflow, the build and test workflows, the web and mobile workflows, the branch and meta workflows, six internal actions and the runner script" />
</p>

<details>
<summary><b>Reusable workflows</b> — 12 in <a href="../.github/workflows">.github/workflows</a></summary>

| Workflow | Purpose |
| --- | --- |
| [`ci-build-trigger-switcher.yaml`](../.github/workflows/ci-build-trigger-switcher.yaml) | central dispatcher, plus the inline `secret-scan`, `secret-scan-notify`, `sast-scan` and `deps-scan` jobs |
| [`ci-build-ntk-on-push-tags-build.yaml`](../.github/workflows/ci-build-ntk-on-push-tags-build.yaml) | lint, unit gate, build, publish, the `trivy-scan` / `sast-scan` / `dast-scan` jobs, notify |
| [`ci-build-ntk-on-push-tags-run-test.yaml`](../.github/workflows/ci-build-ntk-on-push-tags-run-test.yaml) | test runner for `int-test`, `unit-test`, `full-test` tags |
| [`ci-build-ntk-on-push-tags-run-e2e.yaml`](../.github/workflows/ci-build-ntk-on-push-tags-run-e2e.yaml) | reusable E2E test flow |
| [`ci-e2e-tests-manual.yaml`](../.github/workflows/ci-e2e-tests-manual.yaml) | Playwright E2E flow for tagged test runs |
| [`ci-build-ntk-on-push-branches.yaml`](../.github/workflows/ci-build-ntk-on-push-branches.yaml) | placeholder flow for selected branch builds |
| [`ci-build-ntk-on-push-tags-gh-deploy.yaml`](../.github/workflows/ci-build-ntk-on-push-tags-gh-deploy.yaml) | GitHub Pages deploy |
| [`ci-build-ntk-on-push-tags-widget-build.yaml`](../.github/workflows/ci-build-ntk-on-push-tags-widget-build.yaml) | chat widget build |
| [`ci-build-ntk-on-push-tags-mob-apk-build.yaml`](../.github/workflows/ci-build-ntk-on-push-tags-mob-apk-build.yaml) | internal mobile APK build |
| [`ci-build-ntk-on-push-tags-mob-apk-build-public.yaml`](../.github/workflows/ci-build-ntk-on-push-tags-mob-apk-build-public.yaml) | public mobile APK build |
| [`ci-build-ntk-on-push-tags-mob-pwa-build.yaml`](../.github/workflows/ci-build-ntk-on-push-tags-mob-pwa-build.yaml) | mobile PWA, SPA and CRM builds |
| [`ci-build-ntk-on-push-tags-flows-to-pub.yaml`](../.github/workflows/ci-build-ntk-on-push-tags-flows-to-pub.yaml) | publish botflow assets |

Plus one non-reusable meta workflow: [`ci-self-validate.yaml`](../.github/workflows/ci-self-validate.yaml), which validates this repository's own workflows, actions and agent docs, and runs `secret-scan` over nova.ci itself.

Plus two `workflow_dispatch`-only DAST workflows — no `workflow_call`, dispatched by hand from this repository's own Actions tab, never `uses:`-referenced by a caller: [`ci-dast-live-baseline.yaml`](../.github/workflows/ci-dast-live-baseline.yaml), a passive ZAP baseline against the real deployed host through Cloudflare, and [`ci-dast-pentest.yaml`](../.github/workflows/ci-dast-pentest.yaml), a manual **active** ZAP scan (`scan-mode: active`/`full`) for a `choice`-selected repository — no free-text URL input, ever. Its `target` input defaults to `ephemeral` (a GHCR image the workflow boots and tears down); `target: live` instead attacks the same one-host allowlist as the baseline, behind a typed confirmation — real writes and deletions. See [SAST and DAST](sast-dast.md#pentest-active-scan) and [Live target](sast-dast.md#live-target-real-writes-against-a-real-host).

The `secret-scan` job lives inline in the switcher rather than in its own file, so the required-status-check name stays two segments — see [Secret detection](secret-detection.md). The pull-request `sast-scan` job is inline for a different reason: `novatalks.core`'s PR route is a two-entry `build_target` matrix, and source only needs scanning once — see [SAST and DAST](sast-dast.md#semgrep-on-the-pull-request). `deps-scan` sits on the same inline pull-request gate and the same eleven-repository list, reading the checkout's own lockfiles with Trivy fs and OSV-Scanner — see [Dependency scanning](sast-dast.md#dependency-scanning-source-manifests).

</details>

<details>
<summary><b>Internal actions</b> — <a href="../.github/actions">.github/actions</a></summary>

- [`action-cond/action.yml`](../.github/actions/action-cond/action.yml) — composite replacement for the deprecated `haya14busa/action-cond`. Preserves the original interface: inputs `cond`, `if_true`, `if_false`; output `value`. Notifier workflows use it to select success or failure text.
- [`install-docker/action.yml`](../.github/actions/install-docker/action.yml) — ensures the Docker CLI and daemon are available before Docker-based actions or Buildx steps run on self-hosted runners.
- [`gitleaks/action.yml`](../.github/actions/gitleaks/action.yml) — installs a version- and checksum-pinned Gitleaks and runs [`scan.sh`](../.github/actions/gitleaks/scan.sh) over the commits a pull request or push adds, with the central config from [`security/gitleaks/gitleaks.toml`](../security/gitleaks/gitleaks.toml). The only place any workflow may invoke Gitleaks; `validate.sh` fails on a direct call.
- [`semgrep/action.yml`](../.github/actions/semgrep/action.yml) — runs SAST over the checkout with a tag- and digest-pinned Semgrep OSS image and the registry rule packs, via [`scan.sh`](../.github/actions/semgrep/scan.sh). Emits `clean` / `findings` / `error`, never treating an empty result as clean unless the [`canary.yaml`](../.github/actions/semgrep/canary.yaml) rule fired and Semgrep reported no config errors. The only place any workflow may invoke Semgrep. See [SAST and DAST](sast-dast.md).
- [`dast/action.yml`](../.github/actions/dast/action.yml) — boots the built image with its dependencies, runs an OWASP ZAP baseline against it and tears everything down, via [`scan.sh`](../.github/actions/dast/scan.sh). Emits `clean` / `findings` / `not-run` / `error`: an application that failed to boot is a loud skip, not a clean scan. Port, health path, boot timeout and database needs are per-repository inputs. Reads [`zap-baseline.conf`](../.github/actions/dast/zap-baseline.conf), the triage register that decides what a finding *means* — `FAIL` must-fix, `IGNORE` accepted, one line per rule ID with a reason — and treats a missing or malformed register as a broken gate. The only place any workflow may invoke ZAP.
- [`dast/targets.sh`](../.github/actions/dast/targets.sh) — the one per-repository DAST table (port, health path, auth), sourced by `dast_resolve_target <repo> <api|browser>` from the `Resolve DAST target` and `Resolve api-scan target` steps in `ci-build-ntk-on-push-tags-build.yaml`. An unknown repository/surface pair prints `::error::` and fails rather than guessing.
- [`deps-scan/action.yml`](../.github/actions/deps-scan/action.yml) — reads the checkout's own lockfiles with a tag- and digest-pinned OSV-Scanner (invoked via [`scan.sh`](../.github/actions/deps-scan/scan.sh)) and with Trivy fs (`aquasecurity/trivy-action@v0.36.0`, called directly in the `deps-scan` job — there is no wrapper-action rule for Trivy the way there is for Gitleaks, Semgrep and ZAP). Emits `clean` / `findings` / `no-manifests` / `error`: OSV-Scanner's own exit code, not just its JSON body, decides `error` — a real network failure can still leave a well-formed, clean-looking JSON document behind. The only place any workflow may invoke OSV-Scanner. See [SAST and DAST](sast-dast.md#dependency-scanning-source-manifests).
- [`notify/action.yml`](../.github/actions/notify/action.yml) — sends a composed notification to Telegram and Google Chat. Optional per channel; secrets and message text cross into the script through step `env:`, never through expression interpolation.

</details>

<details>
<summary><b>Scripts</b> — <a href="../scripts">scripts</a></summary>

- [`validate.sh`](../scripts/validate.sh) — the one harness to run after any change; see [Validation](validation.md)
- [`test-create-runner.sh`](../scripts/test-create-runner.sh) — offline scenario self-check for the runner script
- [`test-secret-scan.sh`](../scripts/test-secret-scan.sh) — offline scenario self-check for the secret scan, against real git fixtures and the pinned Gitleaks binary
- [`test-sast-scan.sh`](../scripts/test-sast-scan.sh) — offline scenario self-check for the Semgrep scan (`docker` stubbed), covering the canary guard and every fail-closed case
- [`test-deps-scan.sh`](../scripts/test-deps-scan.sh) — offline scenario self-check for the dependency scan (`docker` stubbed for OSV-Scanner; Trivy JSON read from a fixture file), covering `clean` / `findings` / `no-manifests` / `error` and the two silent-zero traps (OSV-Scanner exit 127/129 with a clean-looking JSON body; Trivy's `.Results` key absent or empty)
- [`test-dast-scan.sh`](../scripts/test-dast-scan.sh) — offline scenario self-check for the ZAP baseline scan (`docker` and `curl` stubbed), covering all four outcomes and teardown
- [`test-dast-targets.sh`](../scripts/test-dast-targets.sh) — self-check for the shared per-repository DAST table (`dast/targets.sh`), asserting the shape of every arm and that an unknown repository/surface pair fails rather than guessing
- [`gitleaks-baseline.sh`](../scripts/gitleaks-baseline.sh) — one-time full-history secret audit across the product repositories; deliberately not a CI job

</details>

<details>
<summary><b>Specs and plans</b> — <a href="superpowers">docs/superpowers</a></summary>

Written-up specs and completed-work records, one pair per task, so the reasoning behind a
change is greppable from git history. They are records, not queues — the work is on `main`.

- [`specs/2026-08-27-nc2-2742-secret-detection.md`](superpowers/specs/2026-08-27-nc2-2742-secret-detection.md) — decisions, verified Gitleaks behaviours, discovered constraints, acceptance-criteria mapping
- [`plans/2026-08-27-nc2-2742-secret-detection.md`](superpowers/plans/2026-08-27-nc2-2742-secret-detection.md) — the six commits, step by step, including the two approaches abandoned along the way
- [`specs/2026-08-28-sast-dast-scanning.md`](superpowers/specs/2026-08-28-sast-dast-scanning.md) — why Semgrep and a ZAP baseline rather than CodeQL or SonarQube Community, the fourteen decisions, and the assumptions settled during implementation
- [`plans/2026-08-28-sast-dast-scanning.md`](superpowers/plans/2026-08-28-sast-dast-scanning.md) — the eight tasks, step by step
- [`specs/2026-08-31-scanner-triage.md`](superpowers/specs/2026-08-31-scanner-triage.md) — the eleven decisions behind two-level Semgrep counting, the ZAP triage register and the corrected exit ladder, each citing the upstream `zap-baseline.py` / `zap_common.py` lines it was read from
- [`plans/2026-08-31-scanner-triage.md`](superpowers/plans/2026-08-31-scanner-triage.md) — the four tasks, step by step

</details>

<details>
<summary><b>Agent context</b> — files that keep Claude Code and Codex in sync with these docs</summary>

- [`CLAUDE.md`](../CLAUDE.md) — canonical agent guidance for Claude Code and Codex
- [`AGENTS.md`](../AGENTS.md) — Codex-compatible entry point, delegates to `CLAUDE.md`
- [`.agents/skills/nova-ci/SKILL.md`](../.agents/skills/nova-ci/SKILL.md) — portable Nova CI maintenance skill
- [`.claude/skills/nova-ci/SKILL.md`](../.claude/skills/nova-ci/SKILL.md) — Claude Code mirror of the skill

Keep them synchronized with these docs whenever CI behavior changes.

</details>

---

[← Validation](validation.md) · [Docs index →](README.md)
