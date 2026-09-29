# ARC on dev-01-dev

This is the in-cluster runner scale set `nova-arc`, with labels `self-hosted` and `ci-bootstrap`. For what depends on it and why, see [`docs/pipeline/runners.md`](../../docs/pipeline/runners.md#where-the-bootstrap-runs).

Every command uses `KUBECONFIG=~/kubeconfigs/dev-01-dev.yaml`.

```bash
# Controller (once per cluster)
helm upgrade --install arc oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --version 0.14.2 -n arc-systems --create-namespace

# GitHub App secret: copied from the legacy controller, never printed
kubectl create ns arc-runners
kubectl -n actions-runner-system-prod get secret controller-manager-prod -o json \
  | jq '{apiVersion,kind,type,data,metadata:{name:"nova-arc-github-app",namespace:"arc-runners"}}' \
  | kubectl apply -f -

# Scale set
helm upgrade --install nova-arc oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.14.2 -n arc-runners -f infra/arc/nova-arc.values.yaml
```

To render offline, `helm template` needs `--set controllerServiceAccount.namespace=arc-systems --set controllerServiceAccount.name=arc-gha-rs-controller`, because it cannot look the controller up.

Upgrade the controller and the scale set together, to the same chart version. Keep the runner image and the dind image pinned in the values file, never `latest`.
