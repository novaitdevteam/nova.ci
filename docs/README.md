<p align="center">
  <img src="../assets/readme/hero.svg" width="100%" alt="nova.ci — one switcher routes every NovaTalks repository's pushes, pull requests and tags into shared CI" />
</p>

# nova.ci documentation

Shared GitHub Actions workflows for every NovaTalks product repository.
Start at [Quick start](quick-start.md) if you are wiring a new repository into CI.

## Using CI

| Page | What it answers |
| --- | --- |
| [Quick start](quick-start.md) | What do I add to my repository, and how do I trigger a build? |
| [How a trigger is routed](routing.md) | Which workflow does my push, PR or tag actually call? |
| [Build pipeline](build-pipeline.md) | What runs, in what order, and what gates what? |
| [Tests](tests.md) | Unit vs integration, `test_mode`, and how failures are reported. |

## Operating CI

| Page | What it answers |
| --- | --- |
| [Container scanning (Trivy)](container-scanning.md) | When the scan runs, what it produces, and how to fail on findings. |
| [Runners](runners.md) | How a run gets a Hetzner runner: reuse, caps, create lock, sizing. |
| [Notifications](notifications.md) | What the Telegram and Google Chat messages carry. |

## Maintaining nova.ci

| Page | What it answers |
| --- | --- |
| [Validation](validation.md) | The one harness to run after any workflow change. |
| [Reference](reference.md) | Every reusable workflow, internal action and agent-context file. |

---

[← Repository README](../README.md)
