# Nova CI — runner reliability & cleanup TODO

Working notes for incremental work on the Hetzner self-hosted runner pipeline and
related nova.ci changes. Tick items as they land. Context is kept inline so each
item is actionable on its own later.

> Scope note: only `create-runner.sh` and the switcher/workflows live in **this repo
> (nova.ci)**. The runner watchdog CronJob and the `hcloud-github-runner` action live
> **elsewhere** — flagged per item.

---

## A. Hetzner runner reliability (root causes of 412 / over-provisioning)

- [ ] **P1 — Find the Hetzner project server limit (BLOCKER).**
  - Hetzner Console → project → **Limits** (max servers / vCPU).
  - Confirm the 412 is `resource_limit_exceeded`:
    `curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" -X POST "$HC/servers" -d @create-server.json | jq '.error'`
  - Count current usage: `curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" "$HC/servers" | jq '[.servers[]]|length'`
  - Needed before P2 (sets `MAX_TOTAL_RUNNERS`). Note: one `full-test` needs **2 large (cx53)**
    at once (parallel unit + integration), so the limit must accommodate that.

- [ ] **P4 — Raise the Hetzner limit or free capacity so cx53 (large) can always create.**
  - Either request a project limit increase from Hetzner support, or cap concurrency (P2).
  - Until done, every full-test/int-test push for novatalks.core can 412 when at the cap.

- [x] **P2 — Add a global `MAX_TOTAL_RUNNERS` guard to `ci-build-create-runner.sh`** *(nova.ci)*.
  landed on runner-reliability branch: global cap, env-overridable, default 6 — tune after P1
  - Before creating, count ALL `dev-00-gh-runner-*` Hetzner servers; if `>= MAX_TOTAL_RUNNERS`
    (set just under the P1 project limit), skip creation → wait queue.
  - Today the cap is **per-size (≤2)** and ignores the global project limit, so multiple sizes
    can collectively exceed it → 412 storm.
  - Per repo contract: update README / AGENTS / CLAUDE / SKILL (both mirrors) + run `./scripts/validate.sh`.
  - Depends on **P1**.

- [ ] **P3 — Fail-fast on 412 in the runner action** *(repo: `novaitdevteam/nova.ci.hcloud-github-runner`, `action.sh`)*.
  - On Hetzner 412 / `resource_limit_exceeded`, stop after ~5–10 attempts instead of 360×10s (~1h).
  - Cross-repo change — not editable from nova.ci.

- [x] **P5 — Reduce the race in the per-size max-2 cap** *(nova.ci, `ci-build-create-runner.sh`)*.
  Hetzner-side per-size counting (starting/initializing/running by server_type), jitter 0–9s
  - Concurrent triggers each pass `TOTAL_SIZE < 2` before peers' servers show as starting/initializing
    → over-provisioning (saw 3 small at once). Failed (412) creates also don't count as starting.
  - Harden the count and/or shorten/replace the `sleep $((RANDOM % 60))` race window.
  - This is the race that caused the redundant create even though an online idle large existed.

- [ ] **P6 — GitHub-side sweep for ghost runners (no Hetzner server)** *(k8s/ops, not nova.ci)*.
  - The watchdog iterates **Hetzner servers**, so it never cleans offline `unknown·unknown` GitHub
    runner registrations that have **no VM** (created when server creation 412'd).
  - Add a GitHub-side sweep: deregister `dev-00-gh-runner-*` runners that are `offline` AND have no
    matching Hetzner server. Otherwise they linger ~14 days.

---

## B. nova.ci changes pending merge (uncommitted working tree on `main`)

- [x] **Decide PR strategy (Q7).** Two logically separate changes are staged in the working tree:
  resolved: shipped as single PR #3 (NC2-2103), merged to main
  1. R2/S3 secrets for `novatalks.core` integration tests (`ci-build-ntk-on-push-tags-run-test.yaml` + docs).
  2. `novatalks.engine` deprecation (removed from switcher routing + docs).
  One PR or two? Then create branch(es) + PR(s). Nothing committed yet.

- [x] **Add the 4 repo secrets on `novatalks.core`** for the S3 step:
  `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`.

- [x] **Resolve the switcher version pin (Q8).** Switcher pins build/test workflows at `@NC2-2103`,
  resolved: pins restored to @main before merge (3f2fff4)
  not `@main`. The new S3 step in run-test only activates in the ref the switcher resolves.
  Merge changes into `NC2-2103`, or bump the pins to `@main` after merge. Confirm the team's flow.

---

## C. Open questions

- [ ] **Q9 — Watchdog offline policy.** Currently the Hetzner watchdog deletes orphans (no runner)
  immediately after grace, but offline/idle runners only near the hourly boundary / past
  `MAX_IDLE_AGE` (conservative — protects long jobs whose runner blips offline). Add
  `OFFLINE_IMMEDIATE=true` for strictly-ephemeral runners? Default kept conservative.

---

## Done

- [x] Rewrote the Hetzner runner watchdog to iterate Hetzner servers (catches orphans), with
  fail-closed listing, double busy-check, 422-stop on deregister, grace period. Deployed via
  `dnsConfig` workaround for the broken cluster CoreDNS on `ntk-01-k3ss01`.
- [x] Gated `test → large` runner sizing to `novatalks.core` only in `ci-build-create-runner.sh`
  (other repos: `test → small`). Docs synced, `validate.sh` green.
  (re-landed on runner-reliability branch after being lost in the NC2-2103 merge)
- [x] Added the S3 (Cloudflare R2) file-storage step to `novatalks.core` integration tests
  (gated, secrets via step env). Docs synced, `validate.sh` green.
- [x] Deprecated `novatalks.engine`: removed from all switcher routes (build/protected/PR/test)
  and from docs. Docs synced, `validate.sh` green.
