# ARC scale set for runner bootstrap — design

Date: 2026-09-29. Status: approved in conversation, being implemented.

## Problem

- Since 2026-09-28 around 16:12 UTC, every private repository in the organisation fails with *"The job was not started because recent account payments have failed or your spending limit needs to be increased"*. The organisation has used up its GitHub-hosted minutes.
- The only GitHub-hosted jobs left in the organisation are the two bootstrap jobs in each of the 11 product callers: `Check available runners` and `Create Hetzner Cloud runner`, both `runs-on: ubuntu-latest`.
  - Each one bills a one-minute minimum.
  - September had about 1360 runs.
  - Three of the caller events (`pull_request_target`, `pull_request_review`, `pull_request_review_comment`) reached no job in the switcher. They were dropped in the 11 caller PRs and in nova.ci#65.
- The in-cluster runners on `dev-01-dev` (`actions-runner-system-prod`) are broken:
  - They run legacy summerwind ARC (chart 0.23.7, app 0.27.6), which has had no upstream release since 2023.
  - Their runner image is `v2.331.0`. GitHub forces a self-update to `2.337.0` on every job, and the ephemeral pod exits partway through that update.
  - The pods restart every 20–60 s and jobs sit in `queued`.
- Five repositories have callers with `runs-on: self-hosted` and depend on these runners: `nova.docs`, `novatalks.mobile`, `novatalks.ui-lite`, `novatalks.botflow.flows`, `novatalks.uspacy.connector`.
- The same runners already act as an accidental fallback. When `find-runner` fails, `runner_labels` is empty and the switcher's `|| 'self-hosted'` lands the job on them.

## Decisions

- **D1. Runner Scale Sets, not a newer legacy controller.**
  - Install `gha-runner-scale-set-controller` 0.14.2 in a new namespace, `arc-systems`.
  - Add one organisation-level scale set, `nova-arc`, in `arc-runners`.
  - The new controller uses the `actions.github.com` CRDs and so runs beside the legacy one without conflict.
  - It needs no cert-manager.
- **D2. Labels: `scaleSetLabels: [self-hosted, ci-bootstrap]`.**
  - `ci-bootstrap` is what the callers' two bootstrap jobs will target.
  - `self-hosted` keeps the five legacy callers and the empty-`runner_labels` fallback working, with no workflow change.
  - Hetzner runners also carry `self-hosted`; today they do too.
- **D3. Fallback = shared label, not a GitHub feature.**
  - GitHub has no "try A, else B" in `runs-on`.
  - Once bootstrap runs on `ci-bootstrap`, it no longer depends on billing.
  - When Hetzner cannot create a VM (API down, cap reached), `runner_labels` stays empty and the build lands on `nova-arc` through `self-hosted`.
- **D4. Auth: the existing GitHub App.**
  - Copy it from `controller-manager-prod` into `arc-runners` without printing it.
  - Its keys (`github_app_id`, `github_app_installation_id`, `github_app_private_key`) are exactly the ones the scale-set chart reads.
- **D5. Image `ghcr.io/actions/actions-runner:2.337.0`, dind mode.**
  - The image has bash, curl, jq, git and the docker CLI.
  - It lacks `envsubst`, which `nova.ci.hcloud-github-runner/action.sh` calls, so the pod installs `gettext-base` at start.
  - A baked image is the upgrade path if the start time ever matters.
- **D6. `minRunners: 1`, `maxRunners: 4`.**
  - One warm pod, so bootstrap starts as soon as a job arrives.
  - Four keeps the load inside the cluster's two agent nodes; the legacy set had four pods.
- **D7. The values live in `infra/arc/` in this repository.**
  - They were previously applied by hand, and no copy existed anywhere.
  - They contain no secret.
- **D8. Stopgap first.**
  - Patch the legacy RunnerDeployments to `summerwind/actions-runner:v2.337.0-ubuntu-22.04`, so the five legacy repositories work during the migration.
  - The legacy set is deleted only after `nova-arc` has carried traffic for a few days.

## Out of scope

- cert-manager 1.12 → 1.21: other workloads may use it.
- The `actions-runner-system` (`pilganchuk/botflow`) and `-test` (`novaittestteam`) controllers.
- The k3s upgrade.
- `DenysSamoiliuk/nova.chatsconnector.admin`.
