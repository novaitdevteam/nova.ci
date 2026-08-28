<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="nova.ci — one switcher routes every NovaTalks repository's pushes, pull requests and tags into shared CI" />
</p>

<p align="center">
  <a href="https://github.com/novaitdevteam/nova.ci/actions/workflows/ci-self-validate.yaml"><img src="https://github.com/novaitdevteam/nova.ci/actions/workflows/ci-self-validate.yaml/badge.svg" alt="self-validate status" /></a>
  <a href="./docs/README.md"><img src="https://img.shields.io/badge/docs-nova.ci-1F93FF" alt="documentation" /></a>
</p>

`nova.ci` holds the GitHub Actions workflows that every NovaTalks product repository shares. A product repo keeps one thin caller workflow; everything else — lint, unit tests, secret detection, image build, vulnerability scan, test suites, notifications and self-hosted runner provisioning — lives here and is called from `main`.

**📚 [Read the documentation →](./docs/README.md)**

## Quick start

Add one caller workflow to your repository and hand the event to the switcher:

```yaml
  ci-build-trigger-switcher:
    name: CI Build Trigger Switcher
    uses: novaitdevteam/nova.ci/.github/workflows/ci-build-trigger-switcher.yaml@main
    secrets: inherit
    if: always()
    needs: [find-runner, create-runner]
    with:
      runner_labels: ${{ needs.find-runner.outputs.runner_labels }}
```

Then trigger work with a tag — the workflow consumes (deletes) it after the run:

```bash
git tag build-NC2-1234      && git push origin build-NC2-1234       # build + publish an image
git tag scan-NC2-1234       && git push origin scan-NC2-1234        # build + scan it for CVEs
git tag full-test-NC2-1234  && git push origin full-test-NC2-1234   # unit + integration tests
```

Opening a pull request — drafts included — runs lint and unit tests only: no image, no CVE scan, no notification. Every pull request is also scanned for committed credentials by [secret detection](./docs/secret-detection.md).

→ Full caller workflow, every trigger and the routing rules: **[Quick start](./docs/quick-start.md)** and **[How a trigger is routed](./docs/routing.md)**.

## How it works

<p align="center">
  <img src="./assets/readme/pipeline.gif" width="100%" alt="linter then unit-test run sequentially on every event including pull requests; build-image, trivy-scan and notify run only on push and tag events" />
</p>

`linter` and `unit-test` run sequentially on one runner for every event, pull requests included. Both are advisory — they report red but never block the build. Everything to the right of the dashed line (`build-image`, `trivy-scan`, `notify`) is gated on `github.event_name != 'pull_request'`.

→ **[Build pipeline](./docs/build-pipeline.md)** · **[Tests](./docs/tests.md)** · **[Container scanning](./docs/container-scanning.md)**

## Documentation

| Using CI | Operating CI | Maintaining nova.ci |
| --- | --- | --- |
| [Quick start](./docs/quick-start.md) | [Container scanning (Trivy)](./docs/container-scanning.md) | [Validation](./docs/validation.md) |
| [How a trigger is routed](./docs/routing.md) | [Runners](./docs/runners.md) | [Reference](./docs/reference.md) |
| [Build pipeline](./docs/build-pipeline.md) | [Notifications](./docs/notifications.md) | [`CLAUDE.md`](CLAUDE.md) · [`AGENTS.md`](AGENTS.md) |
| [Tests](./docs/tests.md) | [SAST and DAST](./docs/sast-dast.md) | |
| [Secret detection](./docs/secret-detection.md) | | |

## Validation

Every workflow, action and documentation change is checked by one harness:

```bash
./scripts/validate.sh   # or: make validate
```

[`ci-self-validate.yaml`](.github/workflows/ci-self-validate.yaml) runs the same harness on every pull request and push to `main`. Details in [Validation](./docs/validation.md).
