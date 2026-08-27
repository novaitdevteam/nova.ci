# NC2-2742 — Centralized Secret Detection: Spec

**Ticket:** [NC2-2742](https://sd.novait.com.ua/browse/NC2-2742)
**Status:** implemented — see [the plan](../plans/2026-08-27-nc2-2742-secret-detection.md)
**Date:** 2026-08-27

## Problem

Product repositories hold no CI logic; they call reusable workflows from `nova.ci`.
Secret detection has to land in that architecture — one implementation, all repositories,
no per-repo duplication — and it has to be safe to make a required check without blocking
every pull request on credentials that are already in history.

## Decisions

Each row is a decision that could reasonably have gone the other way. Where the ticket
implied something different, that is called out.

| # | Decision | Why, and what it rules out |
| --- | --- | --- |
| D1 | **Scan the commits an event adds**, not the working tree: merge-base..head for pull requests, `before..after` for pushes | Makes the check safe to enforce on day one — a legacy finding in a default branch cannot fail an unrelated pull request. **Diverges from the ticket's Case 3**, which expected a follow-up delete commit to pass; verified it does not, because the secret is still in the commits that would merge. Remediation is rotate → rewrite branch. |
| D2 | **Job inline in `ci-build-trigger-switcher.yaml`**, not a separate reusable workflow | A reusable-workflow job reports as `<caller job> / <job>`. A third hop would add a third segment to the required-check name. Confirmed against a live PR: names render as `CI Build Trigger Switcher / <job name>`. |
| D3 | **`runs-on: self-hosted`** (user's choice over `ubuntu-latest`) | House style; no GitHub-hosted minutes. Trade-off accepted: the check depends on Hetzner pool availability, so a saturated pool queues the check rather than failing it. |
| D4 | **No `config` input; the central config is resolved from the action's own repo checkout** | Using an action from another repository makes GitHub check out that whole repository, so `security/gitleaks/gitleaks.toml` is on disk at the same `nova.ci` ref as the action. No second checkout, no `curl`, and the two cannot drift apart. |
| D5 | **Push gate = `default_branch` OR `main`/`master`/`development`** | Branch conventions vary: 4 repos default to `development`, 3 to `master`, 3 to `main`, and the signal connector defaults to a feature branch. A hardcoded list would silently never fire there. |
| D6 | **Message composed in `scan.sh`, not in workflow YAML** | The first attempt put it in a `run:` block and broke the YAML on multi-line bash. Logic that cannot be exercised locally does not belong in a security gate. In `scan.sh` it is covered by the harness. |
| D7 | **One path-scoped allowlist, scoped by `targetRules` to `generic-api-key`** | Baseline found 91 of 105 unique `generic-api-key` sites in `novatalks.core` sitting in `.spec`/`.stub`/`test`/`docs`. Provider rules keep full strength there. **Softens the ticket's §7** ("no broad exclusions") in exactly one place, with the safety property asserted by tests. |
| D8 | **Fail closed** — exit `2` on unresolvable range, missing SHA, unreadable config, or an unexplained Gitleaks failure | Never fall back to the built-in rule set: that silently drops the central allowlist. Deliberately the opposite of the runner create lock, which fails open. Blocking a build is cheaper than leaking a credential. |
| D9 | **No SARIF, no report artifact** | SARIF needs `security-events: write`, contradicting §10. The redacted job summary already carries file, line, rule, commit and fingerprint. |
| D10 | **Baseline audit as a local script, not a CI mode** | It is a one-time audit, run and acted on by a human. A permanent CI path for it would be dead weight. |

## Verified behaviours

Facts established empirically against Gitleaks 8.30.1, not assumed.

| Claim | Result |
| --- | --- |
| `--redact` blanks the value in stdout **and** in JSON reports | ✅ `"Secret": "REDACTED"`, `"Match": "REDACTED"` |
| `gitleaks git --log-opts` with unresolvable refs | ⚠️ **exits 0** — reports a clean scan of zero commits. The `git rev-list --count` guard exists for this. |
| A bad config and "leaks found" both exit 1 | ⚠️ indistinguishable by exit code — hence the finding-count check |
| `.gitleaksignore` with a commit-qualified fingerprint | ✅ suppresses |
| `.gitleaksignore` with the commit stripped (`file:rule:line`) | ✅ suppresses — rebase-proof, but pinned to the line number |
| `.gitleaksignore` with a bare file path | ❌ does not suppress |
| A product repo's own `.gitleaks.toml` | ❌ ignored — Gitleaks reads it only when no `--config` is passed |
| `gitleaks:allow` in `.json` | ❌ impossible — JSON has no comments |
| Rule-scoped allowlist: `github-pat` in a `.spec.ts` | ✅ still fails, while a high-entropy string in the same file does not |

## Constraints discovered

1. **Enforcement is blocked by the GitHub plan, not by CI.** The org is on **free**, where
   rulesets are plan-gated for private repositories — same token, private
   `novatalks.core/rulesets` → `403 Upgrade to GitHub Pro`, public `nova.ci/rulesets` →
   `200 []`. Classic branch protection is documented as Pro/Team-only for private repos
   too, but that was **not** verified (needs org admin). What is lost is only the hard
   merge block; detection, reporting and the push net all work.
2. **No staging.** Product repos pin `@main`, and there are 37 internal `@main`
   references plus zero tags. A merge is live on all covered repositories immediately.
   Ticket §13 (`@v1`) is out of scope and tracked separately; partial versioning would be
   worse than none, since a repo pinned to `@v1` would still pull half the pipeline from
   `@main`.
3. **The org has no Actions secrets at org level**, so notifier secrets are per repository
   with no inherited fallback. `nova.chatsconnector.signal-client-api` has the Telegram
   pair but no `GC_NOTIFICATION_WEBHOOK`, so its alerts reach Telegram only, silently.

## Scope

**Covered — 11 repositories**, all reached through their existing caller workflow with no
product-repo change: `novatalks.core`, `novatalks.ui`, `novatalks.ui-lite`,
`nova.botflow`, `novatalks.dialer`, `novatalks.chatwidget`, `novatalks.geoip-api`,
`novatalks.uspacy.connector`, and the telegram, whatsapp and signal chatsconnectors.
`nova.ci` scans itself through `ci-self-validate.yaml`.

**Excluded by decision** — these get no CI coverage; the baseline script is their only
cover and must be aimed at them by hand:

| Repository | Reason |
| --- | --- |
| `novatalks.tests` | test automation; no notifier secrets configured |
| `nova.chatsconnector.genesys.cloud.premium.wizard.engine` | deprecated |
| `nova.ai.marketplace` | out of scope; also no `.github/workflows` at all |
| `novatalks.charts` | out of scope; has only chart workflows, no CI caller |
| `novatalks.grafana.connector` | out of scope; also no `.github/workflows` at all |

**Non-goals:** pre-commit hooks (§ excluded by ticket), CD, `@v1` versioning (§13),
editing product repository callers.

## Acceptance criteria

| # | Criterion | Status |
| --- | --- | --- |
| 1 | Gitleaks integrated into centralized CI | ✅ |
| 2 | Product repos use it via the existing reusable mechanism | ✅ zero product-repo changes |
| 3 | No pre-commit hook | ✅ |
| 4 | No CD | ✅ |
| 5 | Runs on pull requests | ✅ drafts included |
| 6 | Runs on protected/default branch push | ✅ `default_branch` + `main`/`master`/`development` |
| 7 | A new detected secret fails the job | ✅ exit 1, no `continue-on-error` |
| 8 | A clean repository passes | ✅ |
| 9 | Secrets never reach logs in plaintext | ✅ `--redact`, asserted by tests |
| 10 | Version pinned | ✅ 8.30.1 by tag **and** SHA-256 |
| 11 | Central configuration and allowlist mechanism | ✅ `security/gitleaks/gitleaks.toml` |
| 12 | Exceptions cannot disable the scanner uncontrolled | ✅ no input exists; per-finding only |
| 13 | `secret-scan` can be a required status check | ⚠️ name is stable and the job always reports, but **enabling it needs a Team plan** for private repos |
| 14 | Remediation process documented | ✅ [`docs/secret-detection.md`](../../secret-detection.md) |
| 15 | Existing CI jobs and pipelines not broken | ✅ actionlint 287 on `main`, 287 on the branch |

## Baseline audit result

Full-history scan of 13 repositories: **284 findings**, 270 of them `generic-api-key`
(171 unique sites). Classification:

| Class | Count | Action |
| --- | --- | --- |
| Real credential | 1 | IMAP password in `novatalks.tests/ui/helpers/api/email-helper.ts`, live in current code → **rotate** |
| Obsolete / revoked | 1 | `maxmind-license-key` in `novatalks.core` history — key withdrawn, no longer used |
| False positive | 1 | `private-key` in `nova.botflow` README, 2022 — not current |
| Public by design | 10 | Firebase `gcp-api-key` in `novatalks.ui-lite`; `dist/` is now gitignored so they are not recommitted |
| Test-fixture noise | 271 | addressed by D7; `novatalks.core` went 140 → 18 findings |

No `.gitleaksignore` was added to `novatalks.ui-lite`: the findings are historical, so the
gate does not see them, and a pre-emptive commitless entry would rot the first time a line
shifts above it. Handled reactively — the failing check prints the fingerprint to paste.

---

[Implementation plan →](../plans/2026-08-27-nc2-2742-secret-detection.md) · [Secret detection docs](../../secret-detection.md)
