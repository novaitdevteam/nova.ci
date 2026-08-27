# Secret detection (Gitleaks)

Every pull request and every default-branch push in a wired repository is scanned for
credentials by [Gitleaks](https://github.com/gitleaks/gitleaks) before it can merge.
One implementation, in this repository, for all of them — product repositories carry
no Gitleaks configuration and no scanning workflow of their own.

## What runs, and when

| Trigger | Scanned |
| --- | --- |
| Pull request `opened`, `synchronize`, `reopened`, `ready_for_review` | the commits the pull request adds, from its merge base to its head |
| Push to the repository's **default** branch, or to `main` / `master` / `development` | the commits the push adds, `before..after` |
| Anything else — tag pushes, feature-branch pushes, `workflow_dispatch` | nothing; tags point at commits a pull request already scanned |

Draft pull requests are scanned too, unlike the build jobs. The runner is already
provisioned by then, and a secret pushed to a draft is exactly the one that gets
forgotten.

**The scan is scoped to the commits a change adds — never to full history.** That is
what makes it safe to make mandatory on day one: a credential already sitting in a
default branch cannot fail an unrelated pull request. Finding those is the
[baseline audit](#one-time-baseline-audit)'s job, not a blocking check's.

## Where it lives

| Piece | Path |
| --- | --- |
| Rules and allowlists | [`security/gitleaks/gitleaks.toml`](../security/gitleaks/gitleaks.toml) |
| Install and scan | [`.github/actions/gitleaks/action.yml`](../.github/actions/gitleaks/action.yml) |
| Scan logic | [`.github/actions/gitleaks/scan.sh`](../.github/actions/gitleaks/scan.sh) |
| Dispatch for product repositories | the `secret-scan` job in [`ci-build-trigger-switcher.yaml`](../.github/workflows/ci-build-trigger-switcher.yaml) |
| nova.ci scanning itself | the `secret-scan` job in [`ci-self-validate.yaml`](../.github/workflows/ci-self-validate.yaml) |
| Scenario tests | [`scripts/test-secret-scan.sh`](../scripts/test-secret-scan.sh), run by `validate.sh` |
| One-time history audit | [`scripts/gitleaks-baseline.sh`](../scripts/gitleaks-baseline.sh) |

The version is **pinned by release tag and by SHA-256** in `action.yml` — a tag can be
moved and a release asset can be replaced, and `latest` would let an upstream change
silently alter what a mandatory check enforces. `test-secret-scan.sh` reads the pin out
of `action.yml`, so the tests always exercise the version CI runs.

Product repositories need the central config but never fetch it: using an action from
another repository makes GitHub check out **that whole repository** next to it, so
`security/gitleaks/gitleaks.toml` is already on disk at the same nova.ci ref as the
action. No second checkout, no `curl`, and no way for the two to drift apart.

## Which repositories

Wired through the switcher — **no change needed in these repositories**:

`novatalks.core` · `novatalks.ui` · `novatalks.ui-lite` · `nova.botflow` ·
`novatalks.dialer` · `novatalks.tests` · `novatalks.chatwidget` · `novatalks.geoip-api` ·
`novatalks.uspacy.connector` · `nova.chatsconnector.telegram-client-api` ·
`nova.chatsconnector.whatsapp-client-api` · `nova.chatsconnector.signal-client-api`

`nova.ci` scans itself through `ci-self-validate.yaml`, having no caller workflow.

**Out of scope**, by decision on NC2-2742:

| Repository | Why |
| --- | --- |
| `nova.chatsconnector.genesys.cloud.premium.wizard.engine` | deprecated |
| `nova.ai.marketplace` | out of scope (also has no caller workflow) |
| `novatalks.charts` | out of scope (also has no caller workflow) |
| `novatalks.grafana.connector` | out of scope (also has no caller workflow) |

The last three have no `.github/workflows/ci-build-trigger.yaml`, so no event of theirs
would reach this switcher even if they were listed. Bringing one in means adding the
caller workflow from [Quick start](quick-start.md) **in that repository**, then adding
its name to the job's list here.

Note that four repositories default to `development` and three to `master`, and
`nova.chatsconnector.signal-client-api` currently defaults to `NC2-1992_docker`. The
push gate therefore matches `github.event.repository.default_branch` **plus**
`main`/`master`/`development`, rather than a hardcoded list that would silently never
fire.

## Making it a required check

The check name is stable. Use it verbatim:

| Repository | Required status check |
| --- | --- |
| product repositories | `CI Build Trigger Switcher / secret-scan` |
| `nova.ci` | `secret-scan` |

A reusable-workflow job reports as `<caller job name> / <job name>`, which is why the
job is defined inline in the switcher rather than behind another `uses:` — a third hop
would add a third segment to the name every ruleset has to match.

> [!IMPORTANT]
> **Enforcement on the private product repositories is blocked by the GitHub plan, not
> by anything in CI.** The `novaitdevteam` organization is on the **free** plan. With
> the same token, `GET /repos/novaitdevteam/novatalks.core/rulesets` (private) answers
> `403 Upgrade to GitHub Pro or make this repository public to enable this feature`,
> while `GET /repos/novaitdevteam/nova.ci/rulesets` (public) answers `200 []`. Rulesets
> are therefore verified plan-gated for private repositories here. Classic branch
> protection is documented by GitHub as requiring Pro/Team for private repositories
> too, but that half was **not** verified from here — checking it needs org admin
> rights (Settings → Branches on any private repo: either the rule form appears, or an
> upgrade prompt does).
>
> What this costs and does not cost is spelled out under
> [What we lose without enforcement](#what-we-lose-without-enforcement).

Once the plan allows it, per repository: **Settings → Branches → Add branch protection
rule** (or **Rules → Rulesets**) → *Require status checks to pass before merging* → add
the name from the table above.

## What we lose without enforcement

Only the **hard block**. Detection, reporting and the audit trail all work today on
every repository in the list.

| | Free plan (today) | With Team / public |
| --- | --- | --- |
| Scan runs on every pull request | ✅ | ✅ |
| Scan runs on default-branch pushes | ✅ | ✅ |
| Red ❌ check on the pull request, with file, line, rule and fingerprint | ✅ | ✅ |
| Failure recorded against the commit, visible in history | ✅ | ✅ |
| Merge button **disabled** while the check is red | ❌ | ✅ |
| Cannot be bypassed by a hurried or unaware developer | ❌ | ✅ |

So the gap is narrow but real: a developer who sees `secret-scan ❌` can still click
merge, and nothing stops them. The credential is detected, named and logged — it is
just not prevented from landing.

Two things reduce that exposure without changing plan:

1. **The default-branch push scan is a second net.** If a secret does get merged, the
   push scan fails on the default branch straight away, so the finding surfaces within
   a minute of the merge rather than at the next audit. Rotation is the same work; it
   just starts sooner.
2. **The `secret-scan notify` job tells the team.** See below.

### The `secret-scan notify` job

A red check nobody looks at is not a control. When `secret-scan` fails, the
`secret-scan-notify` job sends a message to the same Telegram and Google Chat channels
the build notifier uses, through [`notify/action.yml`](../.github/actions/notify/action.yml)
(`TG_NOTIFICATION_BOT_TOKEN`, `TG_NOTIFICATION_BOT_ID`, `GC_NOTIFICATION_WEBHOOK`, all
via `secrets: inherit`; each channel is skipped when its secret is empty).

It distinguishes three cases, because they need opposite reactions and an alert that
cannot tell them apart is one people learn to ignore:

| Situation | Message |
| --- | --- |
| secret in a pull request | `⚠️ SECRET DETECTED in a pull request` — do not merge; rotate, then rewrite the branch |
| secret on a protected branch | `🚨 SECRET DETECTED on a protected branch` — it is in history now, rotate at the provider immediately |
| the scan itself failed | `🔧 secret-scan could not run` — this change is **UNSCANNED**; a broken gate, not a leak |

The message carries repository, branch or pull request, author, commit, finding count
and a link to the run. It carries **no credential and not even the rule IDs** — the
redacted detail stays in the job summary, behind repository access, because a chat group
is a wider audience than the repository.

The text is composed in [`scan.sh`](../.github/actions/gitleaks/scan.sh), not in the
workflow, so [`test-secret-scan.sh`](../scripts/test-secret-scan.sh) covers it: a chat
alert that is subtly wrong is worse than no alert. If the job dies before `scan.sh` runs
at all (runner lost, download failed), the workflow falls back to a bare
"did not complete" line — silence would look like a clean run.

**On noise.** It fires on every failure, pull requests included, which is the literal
reading of "tell people when something is wrong". A pull request with a stubborn false
positive will therefore alert on every push until it is allowlisted — that is the
intended pressure to allowlist it properly rather than ignore a red check. To narrow it
to protected-branch pushes only (the case where nothing else stops the merge), add
`&& github.event_name == 'push'` to the job's `if:`.

Note that the free plan also cannot restrict who pushes directly to a default branch,
which is a broader hole than this check — direct pushes bypass pull requests entirely,
and the push scan is the only thing watching them.

## A finding failed my check. Now what?

The job summary gives you repository, file, line, rule ID, commit and fingerprint —
everything remediation needs. It does **not** give you the credential: Gitleaks runs
with `--redact`, which blanks the value in stdout and in every report file.

**If it is a real credential:**

1. **Rotate or revoke it first**, at the provider. Assume it is compromised the moment
   it reached a remote — CI logs, forks, clones and caches all saw it.
2. Replace the usage with a GitHub Actions secret or variable, or another approved
   secret store.
3. Remove it from the source.
4. **Rewrite the branch so it leaves git history** — `git rebase -i` or
   `git commit --amend`, then force-push.
5. Push again. The check re-runs on `synchronize`.

> [!WARNING]
> **Deleting the line in a follow-up commit does not clear this check, by design.** The
> secret is still in the commits the pull request would merge, so merging would bury it
> in the default branch's history forever. The scan reads the added commits, not the
> final file tree. Rewriting the branch is the fix.

**If it is a genuine false positive**, pick the narrowest mechanism that works:

1. **`.gitleaksignore` in the product repository** — one line per finding fingerprint,
   copied from the summary:

   ```text
   3f2a9c1e8b7d4a5f6091c2d3e4f5a6b7c8d9e0f1:src/config.ts:generic-api-key:42
   ```

   Exact secret, exact file, exact commit. Note that the fingerprint contains the
   commit SHA, so it stops matching if the branch is later rebased.

2. **An inline `gitleaks:allow` comment** on the offending line — scoped to the line,
   survives rebases, and visible to everyone reading the code:

   ```ts
   const EXAMPLE_TOKEN = "ghp_0000000000000000000000000000000000" // gitleaks:allow
   ```

3. **A rule-scoped allowlist** in [`security/gitleaks/gitleaks.toml`](../security/gitleaks/gitleaks.toml)
   — only for a pattern that is provably never a secret in *any* repository.

There is no input that turns the scanner off. `security/gitleaks/gitleaks.toml`
carries **no path exclusions** on purpose: a broad `tests/**` or `config/**` exclusion
is exactly where a working token gets pasted "just to check something". A false
positive is cheaper to allowlist per finding than a leaked credential is to rotate.

## One-time baseline audit

CI never reads full history, so a credential committed before this check existed will
not fail anything — and would not be noticed either. [`scripts/gitleaks-baseline.sh`](../scripts/gitleaks-baseline.sh)
is the other half: it clones each repository, scans **every branch and tag**, and
writes a redacted per-repository report.

```bash
./scripts/gitleaks-baseline.sh                 # the whole NC2-2742 list
./scripts/gitleaks-baseline.sh novatalks.core  # one repository
```

It is intentionally not a CI job — it is an audit you run once, read, and act on.
Reports land in `.baseline/` (git-ignored). Classify every finding:

| Class | Action |
| --- | --- |
| actual secret | **rotate first**, then remove from source |
| false positive | fingerprint in `.gitleaksignore`, or `gitleaks:allow`, with a reason |
| obsolete / revoked | confirm revoked at the provider, then treat as a false positive |
| test fixture | make it obviously fake, then `gitleaks:allow` the line |

## Permissions

The job runs `permissions: contents: read` and nothing else. It reads commits and
writes a job summary; a leak-detection job is the last place to hold a write token. No
SARIF upload (that would need `security-events: write`) and no report artifact — the
job summary already carries every field remediation needs, redacted.

## Changing the scan

`scan.sh` decides whether a pull request may merge, so
[`scripts/test-secret-scan.sh`](../scripts/test-secret-scan.sh) covers every decision
branch with real git fixtures and the pinned binary — clean and dirty pull requests,
follow-up deletion, branch rewrite, both allowlist mechanisms, merge-base scoping,
push ranges, legacy findings outside the range, new branches, rewritten history, and
four fail-closed cases. `./scripts/validate.sh` runs it. Add a scenario in the same
change as a new branch.

The scan **fails closed**: an unresolvable range, a missing SHA, an unreadable config
or an unexplained Gitleaks failure exits `2` and fails the job. It never falls back to
the built-in rule set, which would silently drop the central allowlist. This is the
opposite of the runner create lock, which [fails open](runners.md#create-lock) —
blocking a build is cheaper than leaking a credential, and the reverse is true there.

> [!NOTE]
> `gitleaks git --log-opts` hands the range to `git log` and **exits 0 when git
> resolves nothing** — a typo or an unfetched SHA would otherwise report a clean scan
> of zero commits. `scan.sh` counts the commits with `git rev-list` first and fails if
> git disagrees. Do not remove that guard.

---

[← Tests](tests.md) · [Docs index](README.md) · [Runners →](runners.md)
