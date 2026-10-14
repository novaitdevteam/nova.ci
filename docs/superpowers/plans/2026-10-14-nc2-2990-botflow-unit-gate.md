# NC2-2990 nova.botflow unit gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The build workflow's unit gate runs nova.botflow's own `npm test` instead of reporting `⏭️ n/a`.

**Architecture:** One new `nova.botflow)` arm in the "Resolve test plan" `case` of `.github/workflows/ci-build-ntk-on-push-tags-build.yaml`. It reuses the install that the lint plan already uses for this repository, and its test command is the repository's own `npm test`. Docs and the rules file name the new arm.

**Tech Stack:** GitHub Actions reusable workflow (bash steps), `./scripts/validate.sh` (zizmor, token permissions, actionlint), Node 24.

**Spec:** [`docs/superpowers/specs/2026-10-14-nc2-2990-botflow-unit-gate-design.md`](../specs/2026-10-14-nc2-2990-botflow-unit-gate-design.md)

## Global Constraints

- Branch `NC2-2990` off `main`. Open a PR and wait for `ci-self-validate` to be green. Merge only when the user asks.
- Commits follow `<type>(NC2-2990): …` and carry no `Co-Authored-By` line.
- Every other repository keeps resolving to `⏭️ n/a (no unit tests configured)`.
- Do not touch `needs`, `if`, `continue-on-error`, permissions, or the End Unit Step logic.
- The command lives in the product repository's `package.json` (`npm test`). Do not hand-assemble `node --test` here.

## Review Focus

1. Other repositories still get the no-op `⏭️ n/a` path: the new arm must not fall through or shadow `*)`. → Task 1 Step 4 (grep the `case`).
2. `npm ci` must work on a clean nova.botflow checkout, which has local `file:` dependencies. → Task 1 Step 1 rehearsal on a fresh clone.
3. nova.botflow's `npm test` must not need network or services on the runner. → Task 1 Step 1: the rehearsal runs with no Redis.
4. A failing botflow test must turn the job red rather than green. → structural: the existing `eval "$PLAN_COMMAND"` under `bash -e`, with no `continue-on-error`. Confirm after merge by reading the PR run log.
5. The notifier and PR check report `✅` only when a command resolved. → unchanged End Unit Step; confirm `UNIT_CHECK=✅` on nova.botflow#368 after merge (Task 1 Step 7).

---

### Task 1: Add the nova.botflow unit-gate arm

**Files:**
- Modify: `.github/workflows/ci-build-ntk-on-push-tags-build.yaml` (the "Resolve test plan" `case`, before `*) ;;  # other repos: no unit gate`)
- Modify: `docs/testing/tests.md:9`
- Modify: `.claude/rules/dispatch-build-test.md:35`

**Interfaces:**
- Consumes: the step outputs `install_command`, `node_cache`, `cache_dependency_path` and `unit_test_command`, read by the existing setup, install and run steps.
- Produces: nothing new.

- [ ] **Step 1: Rehearse the gate's commands on a clean checkout (the "failing test" analogue)**

```bash
D=$(mktemp -d) && git clone -q --branch NC2-2990 https://github.com/novaitdevteam/nova.botflow.git "$D/bf" \
  && cd "$D/bf" && node --version && npm ci --no-audit --no-fund >/dev/null && npm test 2>&1 | grep -E "^ℹ (tests|pass|fail)"; cd - >/dev/null; rm -rf "$D"
```

Expected: Node `v24.x`; `ℹ tests 42`, `ℹ pass 42`, `ℹ fail 0`. If this fails, stop: the arm would only turn the gate red.

- [ ] **Step 2: Add the arm**

Insert before `            *) ;;  # other repos: no unit gate (no-op success)`:

```bash
            nova.botflow)
              # Node's built-in runner over the repository's contract tests: no network, no services.
              set_output install_command "npm ci"
              set_output node_cache "npm"
              set_output cache_dependency_path "package-lock.json"
              set_output unit_test_command "npm test"
              selected_unit_cmd="npm test"
              ;;
```

- [ ] **Step 3: Docs and rule**

In `docs/testing/tests.md:9`, replace `All other standard build repositories resolve to a no-op success` with:

```markdown
`nova.botflow` runs its own `npm test` (Node's built-in `node --test` over its contract tests, no network or services) after `npm ci`. All other standard build repositories resolve to a no-op success
```

In `.claude/rules/dispatch-build-test.md:35`, after the sentence ending `…so its arm runs that repository's own \`npm test\`.`, add:

```markdown
`nova.botflow` has no `test:unit` either; its arm runs its own `npm test` after a plain `npm ci`.
```

- [ ] **Step 4: Check the `case` and run the validator**

```bash
sed -n '/Resolve test plan/,/Selected unit test command/p' .github/workflows/ci-build-ntk-on-push-tags-build.yaml | grep -nE '^\s+[a-z.*]+\)'
./scripts/validate.sh
```

Expected: arms `novatalks.core)`, `novatalks.flowrunner)`, `nova.botflow)`, `*)` in that order. `validate.sh` ends green with no zizmor, permissions or actionlint failures.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci-build-ntk-on-push-tags-build.yaml docs/testing/tests.md .claude/rules/dispatch-build-test.md
git commit -m "ci(NC2-2990): run nova.botflow unit tests in the build gate"
```

- [ ] **Step 6: PR**

Push `NC2-2990` and open a PR against `main` that links NC2-2990 and nova.botflow#368. Wait for `ci-self-validate` to be green. Do not merge without the user's go.

- [ ] **Step 7: After merge (user-triggered)**

Re-run CI on nova.botflow#368 (push or re-run). The `Unit Tests` log must show `Selected unit test command: npm test`, a `ℹ pass 42` line and `UNIT_CHECK=✅`.
