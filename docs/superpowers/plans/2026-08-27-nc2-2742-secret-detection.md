# Centralized Secret Detection Implementation Plan

> [!IMPORTANT]
> **This is a completed-work record, not a queue.** Every step is checked off and carries
> the commit that did it. Do **not** hand this to `subagent-driven-development` or
> `executing-plans` — the work exists on `main`. It is here so the reasoning behind each
> commit is greppable from git history. To change this system, read
> [the spec](../specs/2026-08-27-nc2-2742-secret-detection.md) and
> [`docs/secret-detection.md`](../../secret-detection.md), then write a new plan.

**Goal:** Run Gitleaks over the commits every pull request and default-branch push adds,
across all wired NovaTalks repositories, from one implementation in `nova.ci`.

**Architecture:** A `secret-scan` job inline in `ci-build-trigger-switcher.yaml` — which
already receives every product repository's `push` and `pull_request` events — delegating
to a composite action that installs a pinned Gitleaks and runs `scan.sh`. `scan.sh` holds
all the logic (range resolution, scan, redacted summary, notifier text) so a shell harness
can drive every branch offline. Zero changes in product repositories.

**Tech Stack:** GitHub Actions reusable workflows + composite actions, Gitleaks 8.30.1
(pinned by tag and SHA-256), Bash, TOML.

**Spec:** [`docs/superpowers/specs/2026-08-27-nc2-2742-secret-detection.md`](../specs/2026-08-27-nc2-2742-secret-detection.md)

## Global Constraints

- `GITLEAKS_VERSION=8.30.1`, `GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb` — never `latest`.
- Required-status-check names, stable API: `CI Build Trigger Switcher / secret-scan` for product repositories, `secret-scan` for `nova.ci`.
- `permissions: contents: read` on every scan job. No `security-events: write`, no `contents: write`.
- Always `--redact`. Never emit a credential to logs, summary, artifact or chat.
- Never `continue-on-error` on the scan job.
- Scan only the commits an event adds. Never full history in a blocking check.
- Fail closed: exit `2` rather than fall back to Gitleaks' built-in rule set.
- Do not edit product repository caller workflows.
- `./scripts/validate.sh` must pass, and actionlint must not exceed its pre-existing 287 findings.

---

### Task 1: Central config, scan logic, and the switcher job

**Commit:** `f9cefb8`

**Files:**
- Create: `security/gitleaks/gitleaks.toml`
- Create: `.github/actions/gitleaks/action.yml`
- Create: `.github/actions/gitleaks/scan.sh`
- Create: `scripts/test-secret-scan.sh`
- Create: `scripts/gitleaks-baseline.sh`
- Create: `docs/secret-detection.md`
- Modify: `.github/workflows/ci-build-trigger-switcher.yaml` (new `secret-scan` job)
- Modify: `.github/workflows/ci-self-validate.yaml` (nova.ci scans itself)
- Modify: `scripts/validate.sh`, `.gitignore`, `CLAUDE.md`, `README.md`, `docs/*`, both `SKILL.md` copies

**Interfaces:**
- Produces: `scan.sh` env contract — `GITLEAKS_BIN`, `GITLEAKS_CONFIG`, `GITLEAKS_LOG_FILE`, `GITHUB_EVENT_NAME`, `GITHUB_SHA`, `GITHUB_REF_NAME`, `PR_BASE_SHA`, `PR_HEAD_SHA`, `PR_NUMBER`, `PUSH_BEFORE`, `GITHUB_STEP_SUMMARY`, `GITHUB_OUTPUT`. Exit `0` clean, `1` secrets found, `2` scan untrustworthy.
- Produces: composite action at `novaitdevteam/nova.ci/.github/actions/gitleaks@main`, no inputs.

- [x] **Step 1: Establish the facts before writing anything**

Nothing here is assumed. Resolve the pin and confirm redaction:

```bash
curl -sSL https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_checksums.txt | grep linux_x64
gitleaks git --redact -v --log-opts="$BASE..$HEAD" --report-format json --report-path r.json .
```

Expected: `--redact` yields `"Secret": "REDACTED"` and `"Match": "REDACTED"` in the report,
so no artifact or summary can carry a plaintext value.

- [x] **Step 2: Confirm the required-check name format against a live PR**

```bash
gh api "repos/novaitdevteam/novatalks.core/commits/$SHA/check-runs" --jq '.check_runs[].name'
```

Expected: names render as `CI Build Trigger Switcher / <job name>`. This is what forces the
job to be inline rather than behind another `uses:` — a third hop would add a third segment.

- [x] **Step 3: Probe for the silent-pass trap**

```bash
gitleaks git --log-opts="nosuchref1..nosuchref2" . ; echo "exit=$?"
```

Expected: **`exit=0`** with "no leaks found". An unfetched or mistyped SHA therefore reports
a clean scan of zero commits. Everything below depends on guarding this.

- [x] **Step 4: Write the central config**

`security/gitleaks/gitleaks.toml` — upstream rules, no NovaTalks rules yet, and no path
exclusions:

```toml
[extend]
useDefault = true
```

- [x] **Step 5: Write `scan.sh` with the guard from Step 3**

The load-bearing part — count commits with git before trusting Gitleaks:

```bash
commits="$(git rev-list --count --no-merges $range 2>/dev/null)" \
  || die "git could not resolve the scan range '$range'"
```

Plus merge-base scoping for pull requests (`base.sha` moves while a PR is open), a
tip-commit fallback when the previous tip is unreachable, and a findings-count check so a
Gitleaks startup error is not reported as a leak.

- [x] **Step 6: Write the harness covering every branch**

`scripts/test-secret-scan.sh` — real git fixtures, the pinned binary, version and checksum
read out of `action.yml` so it cannot test a version CI does not run. Fixture credentials
assembled from halves at runtime so no line of the harness trips the scanner:

```bash
P='ghp_'
B1='Xa9Qw3ZbT7yLmN2pRs8VdKcE1fGh4JiO6uPq'   # 36 chars; github-pat is length-exact
LEAK_ONE="${P}${B1}"
```

- [x] **Step 7: Run the harness; fix what it catches**

Run: `./scripts/test-secret-scan.sh`
Expected: 24/24. First run was 23/24 — the `.gitleaksignore` fixture named the wrong rule
because `LEAK_TWO` was 38 chars and matched `generic-api-key`, not `github-pat`. Fixture bug,
not a code bug.

- [x] **Step 8: Wire the job, the self-scan, and the harness into `validate.sh`**

- [x] **Step 9: Verify nothing regressed, then commit**

```bash
./scripts/validate.sh
actionlint | grep -cE '\[[a-z-]+\]$'   # 287 on main, 287 here
git commit
```

---

### Task 2: Narrow the scope to what was actually asked for

**Commit:** `0ea21eb`

**Files:**
- Modify: `.github/workflows/ci-build-trigger-switcher.yaml`, `scripts/gitleaks-baseline.sh`, `docs/secret-detection.md`, `CLAUDE.md`, both `SKILL.md` copies

- [x] **Step 1: Remove repositories added on my own initiative**

Task 1 added `nova.chatsconnector.genesys.cloud.premium.wizard.engine` because it is a
standard build repository. It was not on the NC2-2742 list. Widening scope unasked is as
wrong as narrowing it — removed. Later confirmed deprecated.

- [x] **Step 2: Drop the three repositories with no caller workflow**

`nova.ai.marketplace`, `novatalks.charts`, `novatalks.grafana.connector` — out of scope by
decision. Removed from the baseline default list too, so the audit and the gate agree.

- [x] **Step 3: Downgrade the enforcement claim to what was verified**

Task 1 asserted "private repos get neither branch protection nor rulesets". Only the
rulesets half was verified:

```bash
gh api repos/novaitdevteam/novatalks.core/rulesets   # 403 Upgrade to GitHub Pro
gh api repos/novaitdevteam/nova.ci/rulesets          # 200 []
```

Branch protection could not be checked — the token has `admin: false`, so the endpoint
returns 404 regardless of plan. Docs now say so rather than overclaiming.

- [x] **Step 4: Add "What we lose without enforcement" and commit**

Only the hard merge block. Detection, the red check, and the push net all work on free.

---

### Task 3: Alert the team, since a red check cannot block a merge

**Commit:** `bf091a7`

**Files:**
- Modify: `.github/actions/gitleaks/scan.sh` (`compose()`, `emit()`)
- Modify: `.github/actions/gitleaks/action.yml` (outputs, notifier context env)
- Modify: `.github/workflows/ci-build-trigger-switcher.yaml` (`secret-scan-notify`)
- Modify: `scripts/test-secret-scan.sh`, `scripts/validate.sh`, `docs/*`, `CLAUDE.md`, both `SKILL.md` copies

**Interfaces:**
- Consumes: `scan.sh` from Task 1.
- Produces: step outputs `outcome` (`clean|leaks|error`), `findings`, `message`; job outputs `outcome`, `message`.

- [x] **Step 1: First attempt — compose the message in workflow YAML. Abandoned.**

The multi-line bash landed at column 0 inside a `run: |` block and broke the YAML parse.
The real objection is not the syntax: logic that cannot be exercised locally does not belong
in a security gate.

- [x] **Step 2: Move composition into `scan.sh`**

It already knows event, outcome, count and PR number; the harness already drives it. The
switcher job collapses to ten lines with no shell. Three cases, because they need opposite
reactions:

```
leaks + pull_request  -> ⚠️ SECRET DETECTED in a pull request  — do not merge
leaks + push          -> 🚨 SECRET DETECTED on a protected branch — rotate now
error                 -> 🔧 secret-scan could not run — this change is UNSCANNED
```

No credential and no rule IDs: the redacted detail stays in the job summary, behind
repository access, and a chat group is a wider audience than the repository.

- [x] **Step 3: Add a workflow-level fallback**

If the job dies before `scan.sh` runs, `needs.secret-scan.outputs.message` is empty and the
action would send nothing. Silence looks like a clean run:

```yaml
message: ${{ needs.secret-scan.outputs.message || format('🔧 secret-scan did not complete on {0} — this change is UNSCANNED. …', github.repository, …) }}
```

- [x] **Step 4: Test the message, including that it never leaks the value**

Run: `./scripts/test-secret-scan.sh`
Expected: 44/44, including `notify: PR message never carries the credential` and
`notify: broken gate is not reported as a leak`.

- [x] **Step 5: Fix the Gitleaks guard added in Task 1**

It matched the bare word `gitleaks`, so `id: gitleaks` and `steps.gitleaks.outputs.*`
tripped it. Rewritten to match the two invocation shapes, then **verified against four
violation shapes** rather than assumed:

```bash
run: gitleaks git --redact .        -> caught
uses: gitleaks/gitleaks-action@v2   -> caught
uses: zricethezav/gitleaks@v8       -> caught
run: gitleaks dir .                 -> caught
```

Took three attempts: a missing `/` in the allowlist pattern, then a doubled line-continuation
backslash, then BRE-vs-ERE alternation. Both greps now use `-E`.

- [x] **Step 6: Commit**

---

### Task 4: Calibrate the ruleset against real history

**Commit:** `48fd421`

**Files:**
- Modify: `security/gitleaks/gitleaks.toml` (the one path-scoped allowlist)
- Modify: `.github/workflows/ci-build-trigger-switcher.yaml` (drop `novatalks.tests`)
- Modify: `scripts/test-secret-scan.sh`, `scripts/gitleaks-baseline.sh`, `docs/*`, `CLAUDE.md`, both `SKILL.md` copies

- [x] **Step 1: Run the baseline audit**

```bash
GITLEAKS_BIN=… ./scripts/gitleaks-baseline.sh
```

Result: 284 findings over 13 repositories. 270 `generic-api-key` (171 unique sites); in
`novatalks.core`, 91 of 105 unique sites in `.spec`/`.stub`/`test`/`docs`. One real
credential found — a live IMAP password in `novatalks.tests`, reported for rotation.

- [x] **Step 2: Verify the allowlist form before writing it**

The naive form is dangerous: redefining `[[rules]]` with an existing id under
`useDefault = true` replaces the rule, regex included. The safe form is a rule-scoped
top-level allowlist:

```toml
[[allowlists]]
targetRules = ["generic-api-key"]
paths = ['''\.spec\.[jt]sx?$''', …]
```

Verified on three files: invented token in `.spec.ts` → clean; `github-pat` in the **same**
`.spec.ts` → still fails; same invented token in `src/prod.ts` → still fails.

- [x] **Step 3: Add the allowlist, then measure it on real history**

```
novatalks.core        140 -> 18   (139 -> 17 generic-api-key; maxmind-license-key survived)
novatalks.chatwidget   44 -> 39   (hits are in public/index.html, not a test path)
novatalks.ui-lite      15 -> 15   (gcp-api-key is a provider rule)
```

`chatwidget` barely moving is the evidence the exception is narrow rather than a blanket.

- [x] **Step 4: Turn the safety property into tests**

Four assertions, so a future config edit that drops `targetRules` goes red:

```
allowlist: invented token in a .spec.ts passes
allowlist: provider-rule hit in a .spec.ts STILL fails
allowlist: it fails on the provider rule, not the heuristic
allowlist: same token in product code still fails
```

- [x] **Step 5: Reconcile the invariant I had written in Task 1**

`CLAUDE.md` said "keep the config free of path exclusions" and the config now has one.
Rewritten to state the exact narrow exception and that `targetRules` must never be dropped —
a wrong invariant in the repo is worse than none.

- [x] **Step 6: Drop `novatalks.tests`, and say what exclusion costs**

Test automation, and no notifier secrets — it would have scanned without being able to
alert. Docs now state that an excluded repository gets no CI coverage at all.

- [x] **Step 7: Run the harness and commit**

Run: `./scripts/validate.sh`
Expected: 48/48.

---

### Task 5: Correct the allowlist guidance and verify branch coverage

**Commit:** `6985376`

**Files:**
- Modify: `docs/secret-detection.md`, `scripts/test-secret-scan.sh`

- [x] **Step 1: Test whether a commitless fingerprint works**

The docs warned the fingerprint breaks on rebase without saying what to do instead. Probe
four forms:

```
full fingerprint (commit:file:rule:line)  -> suppresses
commit stripped  (file:rule:line)         -> suppresses   <- rebase-proof
bare file path                            -> does NOT suppress
```

- [x] **Step 2: Add the commitless form as a harness scenario and fix the docs**

Short form while a pull request is in flight; full form for a permanent exception. Both
covered by tests.

- [x] **Step 3: Record two constraints so they are not rediscovered**

A product repository cannot carry its own `gitleaks.toml` — Gitleaks reads
`(target path)/.gitleaks.toml` only when no `--config` is passed, and the action always
passes the central one. And `gitleaks:allow` needs comment syntax, so it does not exist in
`.json`; for `google-services.json`, `.gitleaksignore` is the only option.

- [x] **Step 4: Verify branch coverage per repository**

`branches?per_page=100` was truncated by pagination on the larger repositories, which made
`development` look absent where it exists. Checked branch by branch instead: `master` in all
11, `development` in 9. Both branches the team works on are covered everywhere.

- [x] **Step 5: Decide against a pre-emptive `.gitleaksignore` for `novatalks.ui-lite`**

Findings are historical so the gate does not see them; `dist/` is now gitignored so the key
is no longer recommitted per build; and a pre-emptive commitless entry rots the first time a
line shifts above it. Handled reactively — the failing check prints the fingerprint.

- [x] **Step 6: Run the harness and commit**

Expected: 49/49.

---

### Task 6: Protect the `default_branch` clause from a future "simplification"

**Commit:** `c5b529c`

**Files:**
- Modify: `docs/secret-detection.md`, `CLAUDE.md`, both `SKILL.md` copies

- [x] **Step 1: Mark the signal connector's default as temporary**

`NC2-1992_docker` unifies to `development`/`master` once its regression run finishes. The
gate needs no edit either way — but recorded as a bare fact it invites someone to later
simplify the condition.

- [x] **Step 2: Write down why both halves of the push gate stay**

Once every repository looks conventional, dropping `default_branch` would silently un-cover
the next repository with a non-standard default. The failure mode is a scan that **never
runs** rather than one that errors — the worst kind for a security gate.

- [x] **Step 3: Run the harness and commit**

---

### Task 7: The scanner catches its own harness

**Files:**
- Modify: `scripts/test-secret-scan.sh` (halves convention extended, self-scan assertion)
- Modify: `docs/superpowers/plans/2026-08-27-nc2-2742-secret-detection.md` (this task, and the SHAs the rewrite moved)

- [x] **Step 1: Open the pull request and read the result**

`secret-scan` on PR #17 — nova.ci scanning itself — went **red in 5 seconds**:

```
RuleID:      generic-api-key
File:        scripts/test-secret-scan.sh
Line:        315
```

Task 4 had added `const apiKey = "<32 hex chars>"` spelled out in full, on one line, next
to the keyword. The harness header says the opposite in as many words: *"fixture credentials
are assembled from halves at runtime, so no line of this file matches a gitleaks rule."*
Written in Task 1, broken in Task 4, and not re-checked because the self-scan was run once
in Task 1 and never again.

Redaction held: the log shows `apiKey = "REDACTED"`.

- [x] **Step 2: Fix the fixture the way the file already prescribed**

```bash
H1='8f4c2e9a1b7d'
H2='<remaining hex>'
FAKE_ENTROPY="${H1}${H2}"
```

- [x] **Step 3: Recognise that fixing the working tree is not enough**

The gate reads the **commits**, so the check stayed red: the value was still in the commit
that introduced it. This is exactly the Case 3 semantics from D1, applied to its own author.

The finding classifies as **test fixture**, so the documented remedy is an allowlist. But a
`.gitleaksignore` keyed to branch commit SHAs is dead the moment the PR merges — the same
"dead config" argument used to decline a pre-emptive ignore for `novatalks.ui-lite` in
Task 5. Consistency picked the other option: rewrite the branch.

- [x] **Step 4: Rewrite the branch with an idempotent fix applied per commit**

```bash
git rebase main --exec 'python3 /tmp/fix-fixture.py && (git diff --quiet || (git add -A && git commit --amend --no-edit))'
git log -S'<the literal>' --oneline main..HEAD   # empty
```

The first three commits kept their SHAs; the last four moved, and the SHAs quoted in this
plan were updated to match. A plan that records SHAs has to be re-synced after any rewrite —
worth knowing before choosing to record them.

- [x] **Step 5: Add the assertion that would have caught it before the push**

A final harness scenario runs `scan.sh` over `main..HEAD` — the same range and the same
script `ci-self-validate.yaml` uses — so nova.ci tripping its own scanner now fails
`validate.sh` locally instead of a red PR. Deliberately the commit range and not a tree
scan: `gitleaks dir` ignores `.gitignore` and would fail on any developer's untracked local
`.env`, which was confirmed before choosing.

Run: `./scripts/test-secret-scan.sh`
Expected: 50/50, ending in `self-scan: nova.ci's own commits are clean`.

- [x] **Step 6: Commit and force-push**

---

## Verification

```bash
./scripts/validate.sh          # 49/49 scan.sh scenarios, both transport guards, YAML, skill mirror
./scripts/test-secret-scan.sh  # standalone; exit 99 = skipped (no gitleaks), never a pass
actionlint | grep -cE '\[[a-z-]+\]$'   # 287 on main, 287 here — no new backlog
```

**Not verifiable locally, needs one live run after merge:** that the job comes up on a
self-hosted runner, that the notifier reaches the chat channels, and that job outputs survive
the job failing. The last one is the single unverified assumption in the design; the
workflow-level fallback message is what makes it degrade gracefully if it is wrong.

---

[← Spec](../specs/2026-08-27-nc2-2742-secret-detection.md) · [Secret detection docs](../../secret-detection.md)
