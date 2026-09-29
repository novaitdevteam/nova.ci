---
paths:
  - ".github/workflows/ci-build-create-runner.sh"
  - "scripts/test-create-runner.sh"
  - "docs/pipeline/runners.md"
---

# Runner sizing, pools, caps and lock rules

Loaded when Claude Code reads a matching file; Codex and humans read it from the table in [`CLAUDE.md`](../../CLAUDE.md). Breaking one of these is a regression even when the workflow still parses.

**Runners**

- Keep the `small`/`medium`/`large` sizing matrix scoped to `novatalks.core`; every other repository always resolves to `small`. The one exception is `novatalks.tests`, whose E2E form carries a `runner_size` input (`small` default, `medium`, `large`), read from the event payload the same way `base_ref` is. It exists to measure how many Playwright workers each size carries, and the measurements say to stay on `small`: on 2026-09-18 the full `@e2e` regression took 1.2 h on both `small` (load 5.4 of 4 cores) and `medium` (2.7 of 8) — doubling the cores moved the wall time by zero, because the suite waits on the application and on fixed timeouts, not on CPU. Only the three known sizes pass; anything else, and any push or pull request (no `inputs` in the payload), falls back to `small`, never up.
- **Keep the E2E pool separate from the build pool.** `novatalks.tests` resolves to `e2e-small`/`e2e-medium`, its VMs are named `dev-00-gh-runner-e2e-*`, and every count, cap, reuse filter and create lock is scoped to one pool. The reason is duration, not size: the `@e2e` regression measured 1.2 h on 2026-09-18, so a shared pool parks a suite on one of the two `small` runners for over an hour and queues every other repository behind it. The name prefix stays under `dev-00-gh-runner-` so the leak watchdog and the project-wide total still see these VMs. A build must never reuse an idle E2E runner and an E2E run must never reuse a build one — `scripts/test-create-runner.sh` asserts both directions, plus that a full build pool does not block a suite and that the E2E pool waits at its own cap. That cap is **4** since 2026-09-21, raised from 2: the old number assumed every run shared the stand's one account, which an ephemeral run does not — it brings up its own stack and shares nothing, so the cap was the only thing serialising them. Lab runs are still one at a time, held there by the `concurrency` group on `env_url`. The pool caps itself (`MAX_TOTAL_RUNNERS` becomes `MAX_E2E_RUNNERS` inside it), so raising it cannot take runners from product builds.
- Keep the global `MAX_TOTAL_RUNNERS` cap and Hetzner-state-based per-size counting intact. The per-size cap is **not one number**: `medium` is 4 because it is the scan pool that carries two build targets' parallel `trivy`/`sast`/`dast`/`api` fan-out; `small` and `large` stay 2, where a third VM would idle. `MAX_TOTAL_RUNNERS` (8) is the sum of the three — move them together or the global cap starts denying what the per-size caps allow.
- Keep the four scan jobs on `needs: [build-image]` and **nothing else**. They were chained (`trivy → sast → dast`) on the reasoning that parallel scans would only queue against the cap; the measurement said otherwise — run 33614788933 spent 1017s in gaps against 1083s of work, 397s of it waiting to start `dast-scan`. A chain does not avoid a queue, it guarantees one. Concurrent publishing to the same release is safe because `action-gh-release` retries a `422 already_exists`; do not add a chain back to "fix" a race that upstream already handles.
- Keep the create lock failing open: a lock-machinery error must warn and proceed, never block runner creation.
