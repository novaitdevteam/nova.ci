---
paths:
  - ".github/workflows/ci-build-trigger-switcher.yaml"
  - ".github/workflows/ci-self-validate.yaml"
  - ".github/actions/gitleaks/**"
  - "security/gitleaks/**"
  - "scripts/test-secret-scan.sh"
  - "scripts/gitleaks-baseline.sh"
  - "docs/security/secret-detection.md"
---

# Secret detection rules

Loaded when Claude Code reads a matching file; Codex and humans read it from the table in [`CLAUDE.md`](../../CLAUDE.md). Breaking one of these is a regression even when the workflow still parses.

**Secret detection**

- Keep the check name **`CI Build Trigger Switcher / secret-scan`** (and plain `secret-scan` in `ci-self-validate.yaml`). It is the required-status-check string; renaming the job silently un-protects every repository. That is why the job is inline in the switcher rather than behind another `uses:` — a third hop adds a third name segment.
- Keep both halves of the push gate: `github.ref_name == github.event.repository.default_branch` **and** the `main`/`master`/`development` list. The `default_branch` half is not a workaround for one odd repository — it makes the gate follow whatever a repo treats as its trunk, and removing it once every repo looks conventional silently un-covers the next one that does not. The failure mode is a scan that never runs.
- Keep the scan scoped to the commits an event **adds** (merge-base..head for PRs, `before..after` for pushes). Never make the blocking check read full history: legacy findings would fail every unrelated PR. Full history belongs to `scripts/gitleaks-baseline.sh`.
- Keep `scan.sh` **failing closed** — exit `2` on an unresolvable range, a missing SHA, an unreadable config, or an unexplained Gitleaks failure. Never fall back to Gitleaks' built-in rule set: that silently drops the central allowlist. (Opposite of the runner create lock, which fails open.)
- **Do not remove the `git rev-list --count` guard.** `gitleaks git --log-opts` exits **0** when git resolves nothing, so a bad or unfetched SHA otherwise reports a clean scan of zero commits.
- Keep Gitleaks pinned by version **and** SHA-256 in `gitleaks/action.yml`, never `latest`, and keep `scripts/test-secret-scan.sh` reading that pin so the tests exercise the version CI runs.
- Keep `--redact`. It blanks the value in stdout and in report files. Do not add a SARIF upload (needs `security-events: write`) or a report artifact — the redacted job summary already carries file, line, rule, commit and fingerprint.
- Keep `permissions: contents: read` on the job.
- `secret-scan-notify` is the compensating control for not being able to block a merge on the free plan. Keep the message composed in `scan.sh` (so the harness covers it), keep it free of credentials **and rule IDs** — a chat group is a wider audience than the repository, and the rule ID is in the job summary where repository access gates it. **File paths are not rule IDs and do belong in the message**: a path is usually enough to recognise a fixture or documentation directory, which is the whole reason the notifier exists — so nobody has to open the run to learn that much. Attribute findings to the **commit author Gitleaks reports per finding**, never to `NOTIFY_ACTOR` or `GITHUB_SHA`: on a merge pull request those name whoever opened it and its tip, and `novatalks.core#273` blamed the wrong person for a commit sixteen days older. When findings span several authors or commits, say how many rather than picking the first. Word the remediation by branch shape: rewriting history is right on a topic branch and impossible between two long-lived ones, so a trunk-to-trunk merge is told to fix forward instead — reuse the same trunk definition the push gate uses (`main`/`master`/`development` plus the repository's own `default_branch`), never a second list. Keep the three-way split between a PR leak, a protected-branch leak and a failed scan — an alert that cannot tell a leak from a broken gate is one people ignore. Keep the fallback message for a job that dies before `scan.sh` runs: silence looks like a clean run.
- `security/gitleaks/gitleaks.toml` carries exactly **one** path-scoped allowlist, and it is scoped by `targetRules = ["generic-api-key"]` to the heuristic entropy rule in test-fixture and docs paths. The ~170 provider-specific rules still apply there at full strength — that is the whole safety argument, and `scripts/test-secret-scan.sh` asserts it (a `github-pat` in a `.spec.ts` must still fail). **Never drop `targetRules` and never widen it to a second rule**: that turns it into the blanket `ignore tests/**` that hides real credentials. Any other exception goes through a `.gitleaksignore` fingerprint or an inline `gitleaks:allow`, per finding. There must be no input that disables the scanner.
- Changing `.github/actions/gitleaks/scan.sh` means adding a scenario to `scripts/test-secret-scan.sh` in the same change.
- Out of scope by decision on NC2-2742, do not add without an explicit request: `nova.chatsconnector.genesys.cloud.premium.wizard.engine` (deprecated), `nova.ai.marketplace`, `novatalks.charts`, `novatalks.grafana.connector` (the last three also have no caller workflow, so they never reach the switcher). Excluded repositories get **no** CI coverage; the baseline script is their only cover and must be run against them by hand. `novatalks.tests` was out of scope too until 2026-09-25, when the owner asked for it back: it builds nothing, but it holds the lab's tokens in flow exports and fixtures, and it has notifier secrets now.
