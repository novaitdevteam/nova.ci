# Extract the notifier transport into a composite action

**Date:** 2026-08-27 · **Status:** approved, not yet implemented · **Scope:** bounded

## Problem

Six workflows send the same build notification to Telegram and Google Chat. The
sending steps are copy-paste: the `Send to Telegram` + `Send Message To GChat` pair is
**byte-identical** across `…-tags-build`, `…-mob-apk-build`, `…-mob-pwa-build`,
`…-run-test` and `…-widget-build` (verified by hashing the block in each file);
`…-gh-deploy` carries the Telegram half alone. That is ~217 lines of duplication.

Duplication is the smaller half of the problem. Three defects are replicated by it:

1. **Secret interpolated into the script body.** `const url = "${{ secrets.GC_NOTIFICATION_WEBHOOK }}"`
   contradicts this repository's own rule that secrets reach a step through `env:`.
2. **Message interpolated into a JavaScript template literal.**
   ``JSON.stringify({text: `${{ steps.telegram_message.outputs.value }}`})`` — a message
   containing a backtick or `${` breaks the script or executes as code, and `github.actor`
   and branch names flow into that message.
3. **Google Chat failures are silent.** `webhook();` is called without `await` and its
   result is never checked, so a rejected send leaves no trace. Telegram, in the same
   step pair, throws. Nobody can currently tell how many Google Chat messages were lost.

Separately, `ci-e2e-tests-manual.yaml` has a `notify-telegram` job that composes a
message and never sends it — the send step is simply absent. The job occupies a runner
and produces nothing.

## Design

### The action

`.github/actions/notify/action.yml`, a composite action — the third alongside the
existing `action-cond` and `install-docker`. This follows the established pattern rather
than introducing a new one.

| Input | Required | Behavior |
| --- | --- | --- |
| `message` | yes | the composed notification text |
| `telegram_token` | no | Telegram step is skipped when empty |
| `telegram_to` | no | Telegram step is skipped when empty |
| `gchat_webhook` | no | Google Chat step is skipped when empty |

Both channels are optional because `…-gh-deploy` sends to Telegram only. One action
covers both shapes, and the branch lives in the action instead of in six files.

No `github-token` input: the scripts only `fetch` external APIs, and `actions/github-script`
already defaults to `github.token`.

Both steps route every secret and the message through step `env:` and read them from
`process.env`. No workflow expression is interpolated into a script body. Both check
`response.ok` and throw on failure.

### The call site

39 lines become 6:

```yaml
      - name: Notify
        uses: novaitdevteam/nova.ci/.github/actions/notify@main
        with:
          message: ${{ steps.telegram_message.outputs.value }}
          telegram_token: ${{ secrets.TG_NOTIFICATION_BOT_TOKEN }}
          telegram_to: ${{ secrets.TG_NOTIFICATION_BOT_ID }}
          gchat_webhook: ${{ secrets.GC_NOTIFICATION_WEBHOOK }}
```

The reference is absolute and pinned to `@main`, not `./.github/actions/notify`. These
reusable workflows execute in the calling repository's context, where a relative path
resolves against that repository's checkout. `action-cond` is already referenced this
way and works; this reuses the proven form.

Message composition stays in each workflow. It is genuinely different per workflow and
must not move.

## Scope

**Add:** `.github/actions/notify/action.yml`.

**Replace the transport block with a call:**

- `ci-build-ntk-on-push-tags-build.yaml`
- `ci-build-ntk-on-push-tags-mob-apk-build.yaml`
- `ci-build-ntk-on-push-tags-mob-pwa-build.yaml`
- `ci-build-ntk-on-push-tags-run-test.yaml`
- `ci-build-ntk-on-push-tags-widget-build.yaml`
- `ci-build-ntk-on-push-tags-gh-deploy.yaml` (Telegram only — no `gchat_webhook`)

**Add the missing call:** `ci-e2e-tests-manual.yaml`.

**Leave alone:** `ci-build-ntk-on-push-tags-run-e2e.yaml`, whose notifier is commented
out as legacy.

Expected net change: about −180 lines.

## Behavior changes

Two, both intentional:

1. **Google Chat failures now fail the notifier job.** Today they are silent. The
   notifier runs after the build has finished and gates nothing, so the cost is a red
   job, not a blocked release — and a red job is the point: an undelivered notification
   should be visible.
2. **`ci-e2e-tests-manual` starts sending.** Results of manually triggered E2E runs will
   begin arriving in Telegram and Google Chat. The message text already exists and is
   unchanged; only the send step is new.

Everything else is behavior-preserving. Message text, job names, `needs:`, `if: always()`
and runner selection are untouched.

## Verification

No offline harness exists for YAML notifier steps, so verification is layered:

1. `./scripts/validate.sh` — YAML parse of every workflow and the new action, plus
   `actionlint`.
2. **Message-text invariant:** hash each `Set Telegram Message` block before and after the
   change and assert the hashes are unchanged in all six workflows. This is the property
   that matters — the refactor must not alter a single character of what users receive.
3. **Diff review** of every call site: the action call must sit exactly where the old
   steps sat, under the same `needs:` and `if:`.
4. **One real tag push** on a product repository, confirming both channels deliver.

Steps 1–3 are mechanical and run before the change is proposed for merge. Step 4 needs a
real trigger and is the merge gate.

**Preventing the regrowth.** Nothing stopped the copy-paste from spreading the first
time. `scripts/validate.sh` gains a guard: a workflow line that names `api.telegram.org` or
uses `GC_NOTIFICATION_WEBHOOK` outside the action's `gchat_webhook:` input fails the
harness, since the transport now lives only in the action. Commented-out code is
exempt; it is not a live call.

## Risks

**Rollout ordering.** The workflows will reference `notify@main` while the action itself
lands in the same change. In a single merge commit this is atomic and safe. It breaks
only if someone points the switcher at this branch before merge, because the action does
not exist on `main` yet. Do not test this branch through a branch-pinned switcher.

**Blast radius.** Six workflows and every build notification. Mitigated by the
message-text invariant (verification step 2) and by the fact that the notifier gates
nothing downstream.

**Secret plumbing.** Secrets reach these reusable workflows through the switcher's
`secrets: inherit` and are passed into the action as inputs. Composite actions cannot
read `secrets` directly, so each call site must pass them explicitly — a missed one
silently disables that channel rather than failing loudly. Verification step 3 covers
this; the diff review must confirm every call site passes the channels the old block used.

## Documentation to update

- `docs/notifications.md` — describe the shared action
- `docs/reference.md` and `assets/readme/reference.svg` — two internal actions become three
- `CLAUDE.md` — the "notification jobs stay Docker-free" invariant now points at the action
