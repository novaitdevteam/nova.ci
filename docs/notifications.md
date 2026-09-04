# Notifications

<p align="center">
  <img src="../assets/readme/notifications.svg" width="100%" alt="a build notification carrying build status, lint status, unit test status, a Trivy line colour-coded by worst severity, a SAST line, a DAST line and an API scan line, plus a link to the reports on the build release; a DAST scan that never ran says so rather than reporting clean" />
</p>

Notifier jobs use [`action-cond/action.yml`](../.github/actions/action-cond/action.yml) to select success or failure message text, then hand that text to [`notify/action.yml`](../.github/actions/notify/action.yml), which sends it to Telegram and Google Chat with `actions/github-script@v8` and Node.js `fetch`. Each channel is skipped when its credentials are empty, so a workflow that notifies one channel simply omits the other's inputs, and the Google Chat send is gated on `!cancelled()` rather than on the Telegram step's result — the two channels are independent, and a repository with only `TG_*` configured must still get its Telegram message. Both sends check the response and fail the job when the API rejects the message. No Docker-based actions, and no Docker.

The build message carries:

- `ESLinter Check Status:` — ✅ / ❌
- `Unit Tests Status:` — ✅ passed, ❌ failed, or `⏭️ n/a (no unit tests configured)` when the repository has no unit test plan, so a repo without tests is never reported as if its tests passed
- a **Trivy line** color-coded by worst severity — `🔴 CRITICAL found!`, `🟠 HIGH found`, `🟢 clean`, plus `❌ FAILED` under a fail mode or `⏭️ skipped` when no scan ran — with CRITICAL/HIGH counts and the report download link
- a **SAST line** — `🔍 SAST (Semgrep): 🟢 clean`, `🟡 <n> error · <n> warning` (both levels, always both counts), `❌ scan failed — <reason>`, or `⏭️ skipped (no build to scan)` — with the report download link
- a **DAST line** — `🕷 DAST (ZAP): 🟢 clean · <n> info · <n> accepted`, `🟡 <n> warnings`, `🔴 <n> must-fix · <n> warnings`, `❌ scanner failed — <reason>`, `⏭️ skipped (not a DAST trigger or repository)`, or **`⚠️ not run — <reason>`** — with the report download link
- an **API scan line**, the authenticated ZAP scan for the five opted-in repositories (`novatalks.core`, telegram, whatsapp, signal, `novatalks.dialer`) — the same clean/findings/not-run/error wording as the DAST line above but prefixed `🕷 DAST (ZAP API):` when `scan.sh` composed it, or `🕷 API Scan (ZAP):` for the workflow's own two fallback states (`⏭️ skipped (not an apiscan trigger or repository)`, `❌ scan job failed before reporting`) — the prefix differs because those two lines are composed in the workflow itself, not inside `scan.sh`

The exact wording of all three scanner lines is tabulated on [SAST and DAST](sast-dast.md#in-the-notification); the two pages must agree. A clean DAST run still names its `info` and `accepted` counts, because a suppression nobody can see is a suppression nobody audits, and a `🔴 must-fix` line is a **finding**, not a broken scanner — the build stays green under `warn-only`.

> [!IMPORTANT]
> **`⚠️ not run` is not a colour variant of clean.** It means the application never came
> up, so nothing was scanned; the build is green because a boot-config problem is not a
> security event, but the line has to say so out loud. A notification that reports a
> scan which never happened as `🟢 clean` is the failure both scanners are built to
> avoid — see [SAST and DAST](sast-dast.md#a-scanner-that-could-not-run-is-not-a-clean-scan).

The SAST and DAST lines are composed inside each action's `scan.sh`, not in the workflow, so the scenario harnesses cover the exact wording. The workflow keeps a fallback line for a scan job that died before its `scan.sh` ran at all (`❌ scan job failed before reporting`): silence in a notification reads as a clean scan.

The job summary shows a matching colored alert banner (`CAUTION` / `WARNING` / `NOTE`). Under the default `warn-only` mode the build stays green; the styling is the signal. `warn-only` governs **findings** only — a scanner that could not run reds its own job. The notifier waits for every scan job to finish before sending.


## Secret scan alerts

The `secret-scan-notify` job in [`ci-build-trigger-switcher.yaml`](../.github/workflows/ci-build-trigger-switcher.yaml)
sends to the same two channels when a secret scan fails, and distinguishes a committed
credential (`⚠️` in a pull request, `🚨` on a protected branch) from a scan that could
not run at all (`🔧` — a broken gate, not a leak). It carries no credential and no rule
IDs; the redacted detail stays in the job summary. See
[Secret detection](secret-detection.md#the-secret-scan-notify-job).

---

[← Runners](runners.md) · [Docs index](README.md) · [Validation →](validation.md)
