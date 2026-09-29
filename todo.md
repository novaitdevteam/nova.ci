# Nova CI — open TODO

Only what is still open. Delete an item when it is done; git history keeps it.
Added 2026-09-29.

## Runner infrastructure (outside this repository)

- [ ] **Try `ubuntu-26.04` on one repository, then move the default.** Once
  `nova.ci.hcloud-github-runner#2` merges, one caller passes `image: ubuntu-26.04` and
  runs a real build (Docker, tests, DAST). If it is green, change the action's default:
  one line, and every repository moves. See [`docs/pipeline/runners.md`](docs/pipeline/runners.md#the-hetzner-vm-image).

- [ ] **Remove the `370307291` shim from the action, then delete the snapshot.** The shim
  maps the retired snapshot to `ubuntu-24.04` + latest for branches and tags cut before
  the callers dropped it. Remove it when `image: 370307291` no longer appears anywhere in
  the org, then delete snapshot `370307291` (`github-runner`, 2026-03-26) in Hetzner.

- [ ] **Remove the legacy summerwind controller** (`actions-runner-system-prod`) once
  `nova-arc` has carried the bootstrap for a few days without trouble.

- [ ] **Check the Hetzner project server limit** in Console → project → Limits. The API
  has no endpoint for it. It must be at least 10: `MAX_TOTAL_RUNNERS` is 8, and
  `livekit.demo` and `creatio.demo` live in the same project.

- [ ] **Check whether the `e2e-dev` branch is still needed.** The TEMP job in
  `novatalks.tests`'s `CI-update` branch calls `@e2e-dev`, but the switcher already
  passes `target` and the rest of the E2E form. If that job can move to `@main`, delete
  the job and the branch.
