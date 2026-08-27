# Notify Composite Action Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the copy-pasted Telegram + Google Chat sending steps in six workflows with one composite action, fixing three defects the copy-paste replicated.

**Architecture:** A composite action at `.github/actions/notify/action.yml` exposes `message` plus per-channel credentials; each channel step is skipped when its inputs are empty. Every workflow keeps composing its own message text and calls the action instead of carrying the transport. A grep-based guard in the validation harness stops the duplication from growing back.

**Tech Stack:** GitHub Actions composite actions, `actions/github-script@v8`, Node.js `fetch`, bash + `jq` for the validation harness.

**Spec:** `docs/superpowers/specs/2026-08-27-notify-action-design.md`

## Global Constraints

- Notification jobs stay Docker-free: `actions/github-script@v8` with Node.js `fetch`, never a Docker-based action.
- Secrets reach a step through step `env:` only. No `${{ secrets.* }}` inside a `script:` body.
- No workflow expression may be interpolated into a JavaScript string or template literal. Values cross the boundary through `env:` and are read from `process.env`.
- Action references from these reusable workflows are absolute and pinned: `novaitdevteam/nova.ci/.github/actions/<name>@main`. Never `./.github/actions/<name>` — these workflows run in the caller repository's context.
- Message composition (`Set Telegram Message` steps using `action-cond`) must not change by a single character.
- `./scripts/validate.sh` must be green at the end of every task.
- Do not touch `ci-build-ntk-on-push-tags-run-e2e.yaml`; its notifier is commented out as legacy.

---

### Task 1: Capture the message-text baseline

The refactor's one hard invariant is that users receive identical text. Record the
"before" state first, so later tasks can prove it.

**Files:**
- Create: `/tmp/notify-baseline.txt` (throwaway, never committed)

- [ ] **Step 1: Hash every message-composition block**

```bash
python3 - <<'PY' | tee /tmp/notify-baseline.txt
import re, pathlib, hashlib
for p in sorted(pathlib.Path(".github/workflows").glob("*.yaml")):
    for m in re.finditer(r"      - name: Set Telegram Message\n(?:.*\n)*?(?=      - name: |\n  [a-z]|\Z)", p.read_text()):
        print(hashlib.sha256(m.group(0).encode()).hexdigest()[:16], p.name)
PY
```

Expected: one line per workflow that composes a notification message. Keep this file for Task 6.

- [ ] **Step 2: Confirm the transport blocks are what the spec claims**

```bash
python3 - <<'PY'
import re, pathlib, hashlib
seen = {}
for p in sorted(pathlib.Path(".github/workflows").glob("*.yaml")):
    m = re.search(r"      - name: Send to Telegram\n(.*?)\n            webhook\(\);\n", p.read_text(), re.S)
    if m: seen[p.name] = hashlib.sha256(m.group(0).encode()).hexdigest()[:12]
print(seen); print("distinct:", len(set(seen.values())))
PY
```

Expected: five files, `distinct: 1`. If a file has drifted, stop and re-read the spec's scope section — a drifted block needs its difference preserved, not flattened.

---

### Task 2: Create the composite action

**Files:**
- Create: `.github/actions/notify/action.yml`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: an action taking inputs `message` (required), `telegram_token`, `telegram_to`, `gchat_webhook` (all three optional, default `''`). Tasks 3–5 call it by this exact input set.

- [ ] **Step 1: Write the action**

```yaml
name: Notify
description: Send a build notification to Telegram and Google Chat. Each channel is skipped when its credentials are empty.

inputs:
  message:
    description: Notification text to send, already composed by the calling workflow.
    required: true
  telegram_token:
    description: Telegram bot token. Leave empty to skip Telegram.
    required: false
    default: ''
  telegram_to:
    description: Telegram chat id. Leave empty to skip Telegram.
    required: false
    default: ''
  gchat_webhook:
    description: Google Chat incoming webhook URL. Leave empty to skip Google Chat.
    required: false
    default: ''

runs:
  using: composite
  steps:
    - name: Send to Telegram
      if: inputs.telegram_token != '' && inputs.telegram_to != ''
      uses: actions/github-script@v8
      env:
        TELEGRAM_TO: ${{ inputs.telegram_to }}
        TELEGRAM_TOKEN: ${{ inputs.telegram_token }}
        TELEGRAM_MESSAGE: ${{ inputs.message }}
      with:
        script: |
          const params = new URLSearchParams({
            chat_id: process.env.TELEGRAM_TO,
            text: process.env.TELEGRAM_MESSAGE,
          });
          const response = await fetch(`https://api.telegram.org/bot${process.env.TELEGRAM_TOKEN}/sendMessage`, {
            method: "POST",
            headers: {"Content-Type": "application/x-www-form-urlencoded"},
            body: params,
          });
          if (!response.ok) {
            throw new Error(`Telegram sendMessage failed: ${response.status} ${await response.text()}`);
          }

    - name: Send to Google Chat
      if: inputs.gchat_webhook != ''
      uses: actions/github-script@v8
      env:
        GCHAT_WEBHOOK: ${{ inputs.gchat_webhook }}
        GCHAT_MESSAGE: ${{ inputs.message }}
      with:
        script: |
          const response = await fetch(process.env.GCHAT_WEBHOOK, {
            method: "POST",
            headers: {"Content-Type": "application/json; charset=UTF-8"},
            body: JSON.stringify({text: process.env.GCHAT_MESSAGE}),
          });
          if (!response.ok) {
            throw new Error(`Google Chat webhook failed: ${response.status} ${await response.text()}`);
          }
```

Note what changed from the copied original, and why: the webhook URL and the message
now arrive through `env:` and are read from `process.env`, so no secret and no
user-controlled text is interpolated into the script body; the Google Chat call is
awaited and its status checked, matching Telegram.

- [ ] **Step 2: Verify it parses**

Run: `./scripts/validate.sh`
Expected: the YAML section lists `OK .github/actions/notify/action.yml`, and the run ends `VALIDATION OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/actions/notify/action.yml
git commit -m "Add a shared notify composite action for Telegram and Google Chat"
```

---

### Task 3: Migrate the five identical workflows

**Files:**
- Modify: `.github/workflows/ci-build-ntk-on-push-tags-build.yaml:872-910`
- Modify: `.github/workflows/ci-build-ntk-on-push-tags-mob-apk-build.yaml:243-281`
- Modify: `.github/workflows/ci-build-ntk-on-push-tags-mob-pwa-build.yaml:217-255`
- Modify: `.github/workflows/ci-build-ntk-on-push-tags-run-test.yaml:360-398`
- Modify: `.github/workflows/ci-build-ntk-on-push-tags-widget-build.yaml:107-145`

**Interfaces:**
- Consumes: the action from Task 2, by its four input names.
- Produces: nothing later tasks depend on.

Line numbers shift as you edit; match on content, not position.

- [ ] **Step 1: Replace each transport block with the action call**

In each of the five files, delete everything from `      - name: Send to Telegram`
through the closing `            webhook();` line, and put this in its place:

```yaml
      - name: Notify
        uses: novaitdevteam/nova.ci/.github/actions/notify@main
        with:
          message: ${{ steps.telegram_message.outputs.value }}
          telegram_token: ${{ secrets.TG_NOTIFICATION_BOT_TOKEN }}
          telegram_to: ${{ secrets.TG_NOTIFICATION_BOT_ID }}
          gchat_webhook: ${{ secrets.GC_NOTIFICATION_WEBHOOK }}
```

Because all five blocks are byte-identical, this is scriptable:

```bash
python3 - <<'PY'
import re, pathlib
CALL = """      - name: Notify
        uses: novaitdevteam/nova.ci/.github/actions/notify@main
        with:
          message: ${{ steps.telegram_message.outputs.value }}
          telegram_token: ${{ secrets.TG_NOTIFICATION_BOT_TOKEN }}
          telegram_to: ${{ secrets.TG_NOTIFICATION_BOT_ID }}
          gchat_webhook: ${{ secrets.GC_NOTIFICATION_WEBHOOK }}
"""
pattern = re.compile(r"      - name: Send to Telegram\n.*?\n            webhook\(\);\n", re.S)
for p in sorted(pathlib.Path(".github/workflows").glob("*.yaml")):
    t = p.read_text()
    new, n = pattern.subn(CALL, t)
    if n:
        p.write_text(new)
        print(f"{p.name}: replaced {n} block(s)")
PY
```

Expected output: exactly five files, one block each.

- [ ] **Step 2: Verify no transport survived outside the action**

```bash
grep -rn "api.telegram.org\|webhook()" .github/workflows/ | grep -v "^\S*run-e2e"
```

Expected: no output. Anything printed (other than the commented-out `run-e2e` block) is a block the pattern missed.

- [ ] **Step 3: Verify the message text is untouched**

```bash
python3 - <<'PY' > /tmp/notify-after.txt
import re, pathlib, hashlib
for p in sorted(pathlib.Path(".github/workflows").glob("*.yaml")):
    for m in re.finditer(r"      - name: Set Telegram Message\n(?:.*\n)*?(?=      - name: |\n  [a-z]|\Z)", p.read_text()):
        print(hashlib.sha256(m.group(0).encode()).hexdigest()[:16], p.name)
PY
diff /tmp/notify-baseline.txt /tmp/notify-after.txt && echo "message text unchanged"
```

Expected: `message text unchanged`. Any diff means a message block was damaged — revert and redo the replacement.

- [ ] **Step 4: Validate**

Run: `./scripts/validate.sh`
Expected: `VALIDATION OK`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows
git commit -m "Call the shared notify action from the five build workflows"
```

---

### Task 4: Migrate the Telegram-only workflow

`ci-build-ntk-on-push-tags-gh-deploy.yaml` never sent to Google Chat. Preserve that:
omit `gchat_webhook` so the action skips the channel.

**Files:**
- Modify: `.github/workflows/ci-build-ntk-on-push-tags-gh-deploy.yaml:67-87`

- [ ] **Step 1: Replace the Telegram block**

Delete lines 67–87 (`      - name: Send to Telegram` through the closing `            }`
of the `if (!response.ok)` guard) and put this in their place:

```yaml
      - name: Notify
        uses: novaitdevteam/nova.ci/.github/actions/notify@main
        with:
          message: ${{ steps.telegram_message.outputs.value }}
          telegram_token: ${{ secrets.TG_NOTIFICATION_BOT_TOKEN }}
          telegram_to: ${{ secrets.TG_NOTIFICATION_BOT_ID }}
```

- [ ] **Step 2: Confirm Google Chat stays absent**

```bash
grep -c "gchat_webhook" .github/workflows/ci-build-ntk-on-push-tags-gh-deploy.yaml
```

Expected: `0`. This workflow deliberately notifies one channel; adding the second here is a scope change, not a refactor.

- [ ] **Step 3: Validate**

Run: `./scripts/validate.sh`
Expected: `VALIDATION OK`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci-build-ntk-on-push-tags-gh-deploy.yaml
git commit -m "Call the shared notify action from the gh-deploy workflow"
```

---

### Task 5: Make the manual E2E notifier actually send

`ci-e2e-tests-manual.yaml` composes a message in its `notify-telegram` job and has no
send step at all, so the job occupies a runner and produces nothing.

**Files:**
- Modify: `.github/workflows/ci-e2e-tests-manual.yaml` — append to the `notify-telegram` job

- [ ] **Step 1: Confirm the job really has no send step**

```bash
sed -n '/^  notify-telegram:/,$p' .github/workflows/ci-e2e-tests-manual.yaml | grep -c "Send to Telegram\|uses: actions/github-script"
```

Expected: `0`.

- [ ] **Step 2: Append the action call**

Add as the last step of the `notify-telegram` job, immediately after the
`Set Telegram Message` step's `if_false:` block:

```yaml
      - name: Notify
        uses: novaitdevteam/nova.ci/.github/actions/notify@main
        with:
          message: ${{ steps.telegram_message.outputs.value }}
          telegram_token: ${{ secrets.TG_NOTIFICATION_BOT_TOKEN }}
          telegram_to: ${{ secrets.TG_NOTIFICATION_BOT_ID }}
          gchat_webhook: ${{ secrets.GC_NOTIFICATION_WEBHOOK }}
```

- [ ] **Step 3: Validate**

Run: `./scripts/validate.sh`
Expected: `VALIDATION OK`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci-e2e-tests-manual.yaml
git commit -m "Send the manual E2E notification that was composed but never delivered"
```

---

### Task 6: Guard against the duplication returning

Nothing stopped the copy-paste last time. One grep in the harness does.

**Files:**
- Modify: `scripts/validate.sh` — new section before `section "actionlint"`

- [ ] **Step 1: Add the guard**

Insert immediately before the `section "actionlint"` line:

```bash
section "Notifier transport"
# The Telegram/Google Chat transport lives in .github/actions/notify only. A workflow
# that talks to those APIs directly is the copy-paste this action replaced.
offenders="$(grep -ln 'api\.telegram\.org' .github/workflows/*.yaml | grep -v 'run-e2e' || true)"
if [ -z "$offenders" ]; then
  echo "OK: no workflow sends notifications directly"
else
  printf '%s\n' "$offenders" | sed 's/^/       /'
  echo "ERROR: these workflows send notifications directly; use .github/actions/notify"
  fail=1
fi
```

- [ ] **Step 2: Verify it passes now**

Run: `./scripts/validate.sh`
Expected: `OK: no workflow sends notifications directly`, run ends `VALIDATION OK`.

- [ ] **Step 3: Verify it actually catches a regression**

A guard that never fails is decoration. Prove it fails:

```bash
cp .github/workflows/ci-build-ntk-on-push-tags-widget-build.yaml /tmp/widget-backup.yaml
printf '\n# https://api.telegram.org/botX/sendMessage\n' >> .github/workflows/ci-build-ntk-on-push-tags-widget-build.yaml
./scripts/validate.sh 2>&1 | grep -q "send notifications directly" && echo "guard works"
cp /tmp/widget-backup.yaml .github/workflows/ci-build-ntk-on-push-tags-widget-build.yaml
./scripts/validate.sh 2>&1 | tail -1
```

Expected: `guard works`, then `VALIDATION OK` after the restore.

- [ ] **Step 4: Commit**

```bash
git add scripts/validate.sh
git commit -m "Fail validation when a workflow sends notifications directly"
```

---

### Task 7: Sync the documentation

Per the repository contract, a behavior change updates its docs page, the diagram if the
diagram now lies, `CLAUDE.md` if an invariant changed, and both skill mirrors.

**Files:**
- Modify: `docs/notifications.md`
- Modify: `docs/reference.md`
- Modify: `assets/readme/reference.svg`
- Modify: `CLAUDE.md`
- Modify: `.agents/skills/nova-ci/SKILL.md` and `.claude/skills/nova-ci/SKILL.md`

- [ ] **Step 1: Update `docs/notifications.md`**

Replace the sentence describing the senders with:

```markdown
Notifier jobs use [`action-cond/action.yml`](../.github/actions/action-cond/action.yml) to select success or failure message text, then hand that text to [`notify/action.yml`](../.github/actions/notify/action.yml), which sends it to Telegram and Google Chat with `actions/github-script@v8` and Node.js `fetch`. Each channel is skipped when its credentials are empty, so a workflow that notifies one channel simply omits the other's inputs. Both sends check the response and fail the job when the API rejects the message. No Docker-based actions, and no Docker.
```

- [ ] **Step 2: Update `docs/reference.md`**

In the `INTERNAL ACTIONS` list, add after `install-docker`:

```markdown
- [`notify/action.yml`](../.github/actions/notify/action.yml) — sends a composed notification to Telegram and Google Chat. Optional per channel; secrets and message text cross into the script through step `env:`, never through expression interpolation.
```

- [ ] **Step 3: Update the diagram**

In `assets/readme/reference.svg`, the `INTERNAL ACTIONS` card lists two entries and the
header reads `13 workflows · 2 actions · 1 script`. Add `notify` as a third entry and
change the header to `13 workflows · 3 actions · 1 script`. Re-render to check:

```bash
rsvg-convert -w 1200 assets/readme/reference.svg -o /tmp/ref.png
```

Confirm the third line fits inside its card at GitHub width.

- [ ] **Step 4: Update `CLAUDE.md`**

Replace the notifier invariant bullet with:

```markdown
- Keep notification jobs Docker-free and routed through [`notify/action.yml`](.github/actions/notify/action.yml): `actions/github-script@v8` with Node.js `fetch`. A workflow must not call the Telegram or Google Chat API directly — `validate.sh` fails on it.
```

- [ ] **Step 5: Update both skill mirrors**

Add to the file list in `.agents/skills/nova-ci/SKILL.md`, then copy the file over its
`.claude/` mirror so `validate.sh`'s mirror check passes:

```markdown
- `.github/actions/notify/action.yml`: the only place that talks to Telegram and Google Chat
```

```bash
cp .agents/skills/nova-ci/SKILL.md .claude/skills/nova-ci/SKILL.md
```

- [ ] **Step 6: Validate and review the whole diff**

```bash
./scripts/validate.sh
git diff -- .github/workflows .github/actions scripts docs README.md AGENTS.md CLAUDE.md .agents .claude
```

Expected: `VALIDATION OK`, and a diff in which no `Set Telegram Message` block appears.

- [ ] **Step 7: Commit**

```bash
git add docs CLAUDE.md .agents .claude assets/readme/reference.svg
git commit -m "Document the shared notify action"
```

---

## Merge gate

Steps above are all offline. One thing cannot be verified without a real trigger, and it
is the thing that matters:

- [ ] Push a `build-*` tag on one product repository and confirm the notification arrives in **both** Telegram and Google Chat with unchanged text.

Do not point a branch-pinned switcher at this branch before merge: the workflows
reference `notify@main`, and the action only exists on `main` after the merge commit.
