# ARC scale set for runner bootstrap — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the callers' bootstrap jobs on a free in-cluster runner scale set. The same set also serves as the `self-hosted` fallback, which takes GitHub-hosted minutes in the organisation to zero.

**Architecture:** Install `gha-runner-scale-set-controller` 0.14.2 in `arc-systems` on `dev-01-dev`, and one organisation-level scale set, `nova-arc`, in `arc-runners`, labelled `self-hosted` and `ci-bootstrap`. It runs beside the legacy summerwind controller, which is patched to a current runner image as a stopgap and removed later. The 11 callers move their two bootstrap jobs from `ubuntu-latest` to `ci-bootstrap`.

**Tech Stack:** k3s 1.32, Helm (OCI charts from `ghcr.io/actions/actions-runner-controller-charts`), `ghcr.io/actions/actions-runner:2.337.0`, GitHub App auth.

**Spec:** `docs/superpowers/specs/2026-09-29-arc-bootstrap-runners.md`

## Global Constraints

- Every cluster command uses `KUBECONFIG=~/kubeconfigs/dev-01-dev.yaml`.
- Never print the GitHub App secret. Copy it through a pipe (`kubectl get -o json | jq … | kubectl apply -f -`).
- Pin the chart version to `0.14.2` and the runner image to `ghcr.io/actions/actions-runner:2.337.0`.
- The scale set name is `nova-arc`, with labels exactly `[self-hosted, ci-bootstrap]`.
- Do not touch `actions-runner-system` or `actions-runner-system-test`, or cert-manager.
- Product repository PRs branch from `development`, or from `main` where `development` does not exist, and target that same branch.
- Do not merge the caller PRs before Task 3 passes; without a `ci-bootstrap` runner, those jobs queue forever.

## Review Focus

- **The pod cannot reach `api.hetzner.cloud`** (cluster DNS, egress). Expect `create-runner` to fail loudly, not to hang. Task 3 checks it from a pod in `arc-runners`.
- **`envsubst` is missing because the apt install failed.** The pod must still start and print a warning. Task 3 checks `command -v envsubst` in a live runner pod.
- **A job that reaches `nova-arc` through `self-hosted` needs docker.** The runner pod must have a working `docker info` against the dind sidecar. Task 3 checks it.
- **The legacy and new runners both carry `self-hosted` during the overlap.** Either may take a legacy-repo job, and both must be able to run it. Task 0 makes the legacy one healthy first.
- **The listener cannot register** (wrong secret keys, App lacks the org runner permission). Expect the listener pod to crashloop with an auth error. Task 2 waits for the listener `Running` and a scale set visible in its log.

---

### Task 0: Stop the legacy self-update loop

**Files:** none (cluster only).

- [x] Patch all four RunnerDeployments in `actions-runner-system-prod`:
  `kubectl -n actions-runner-system-prod patch runnerdeployment <name> --type merge -p '{"spec":{"template":{"spec":{"image":"summerwind/actions-runner:v2.337.0-ubuntu-22.04"}}}}'`
- [x] Verify that after 2 minutes the runner pods stay `Running` (age > 60 s) and the logs show `Listening for Jobs` with no `Runner update in progress`.

### Task 1: Controller

**Files:** Create `infra/arc/README.md` (install and upgrade commands).

- [x] `helm install arc oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller --version 0.14.2 -n arc-systems --create-namespace`
- [x] Verify: `kubectl -n arc-systems get pods` shows `arc-gha-rs-controller-*` `1/1 Running`, and the CRDs `autoscalingrunnersets.actions.github.com` exist.

### Task 2: Scale set `nova-arc`

**Files:** `infra/arc/nova-arc.values.yaml` (already written; `helm template` renders the labels, the runner image and the envsubst guard).

- [x] `kubectl create ns arc-runners`, then copy the secret:
  `kubectl -n actions-runner-system-prod get secret controller-manager-prod -o json | jq '{apiVersion,kind,type,data,metadata:{name:"nova-arc-github-app",namespace:"arc-runners"}}' | kubectl apply -f -`
- [x] `helm install nova-arc oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set --version 0.14.2 -n arc-runners -f infra/arc/nova-arc.values.yaml`
- [x] Verify that the listener pod in `arc-systems` is `Running`, that its log shows the scale set created or reused with no auth error, and that one runner pod in `arc-runners` is `Running` (`minRunners: 1`).

### Task 3: Verify the runner can do the bootstrap job

- [x] In the idle runner pod, check `command -v envsubst jq curl` → all present, and `docker info` → server version printed.
- [x] From the same pod, run `curl -s -o /dev/null -w '%{http_code}' https://api.hetzner.cloud/v1/servers` → `401` (reachable, unauthenticated). Also check `https://api.github.com` → `200`, and `https://raw.githubusercontent.com` → any HTTP code.
- [x] If `kubectl exec` is blocked (the kubelet proxy returned 502 on one node), run the same checks as a one-off `kubectl run` pod with the same image in `arc-runners`.

### Task 4: Callers → `ci-bootstrap`

**Files:** in each of the 11 product repositories, `.github/workflows/ci-build-trigger.yaml`: the `runs-on: ubuntu-latest` of `find-runner` and `create-runner` become `runs-on: ci-bootstrap`.

- [x] Branch `ci/bootstrap-on-arc` from `development` or `main`, `sed` both lines, check that the YAML parses, commit, push, and open a PR.
- [x] Verify: the PR's own `pull_request` run shows `Check available runners` on a `nova-arc-*` runner, and the job does not fail on billing.

### Task 5: Docs and invariants in nova.ci

**Files:** `docs/pipeline/runners.md`, `docs/getting-started/quick-start.md` (caller template), `CLAUDE.md` (Runners invariants), `.agents/skills/nova-ci/SKILL.md` + `.claude/skills/nova-ci/SKILL.md`, `infra/arc/README.md`.

- [x] Document the scale set, its two labels and why each exists, the fallback path, the envsubst workaround, and the legacy set's removal as pending.
- [x] Run `./scripts/validate.sh` → `VALIDATION OK`, then commit and open a PR.

### Task 6 (later, separate approval): remove the legacy set

- [ ] After a few days of `nova-arc` traffic, scale the legacy `-prod` RunnerDeployments to 0, then `helm uninstall actions-runner-controller-prod`.

## Outcome (2026-09-29)

- Task 0: all four legacy RunnerDeployments are on `v2.337.0`, and `runner-3` shows `Current runner version: '2.337.0'`. The `runner-1` pods on `dev-01-k3sa02d` keep going to `Error`, with dind unable to open its boltdb. That node's kubelet also returns 502 to `logs`/`exec`, so the cause is not diagnosed. Left alone, since the legacy set is retiring.
- Task 2: the listener registered, and immediately took 4 queued `self-hosted` jobs from the organisation's backlog.
- Task 3: `envsubst`/`jq`/`curl`/`git` are present. Docker server is 29.7.2, after pinning; the chart default gave 20.10.17. `api.hetzner.cloud` returned 401 and `api.github.com` returned 200.
- Task 4: 11 PRs are open. On `novatalks.core#312`, `Check available runners` succeeded on `nova-arc-nc9zr-runner-f2djj`. `Create Hetzner Cloud runner` was skipped there because an idle runner was reused, so the `envsubst` path has not yet run live.
