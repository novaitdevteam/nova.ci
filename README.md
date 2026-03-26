# `nova.ci`

Shared GitHub Actions workflows for NovaTalks repositories.

## Main entrypoint

The primary reusable workflow is [`ci-build-trigger-switcher.yaml`](/Users/deniszm/novatalks/nova.ci/.github/workflows/ci-build-trigger-switcher.yaml). It receives `push` events from connected repositories and routes execution to a specific workflow based on:

- repository name
- ref type: branch or tag
- ref name or commit message

## Implemented workflows

Current workflows in [`.github/workflows`](/Users/deniszm/novatalks/nova.ci/.github/workflows):

- [`ci-build-trigger-switcher.yaml`](/Users/deniszm/novatalks/nova.ci/.github/workflows/ci-build-trigger-switcher.yaml): central dispatcher
- [`ci-build-ntk-on-push-tags-build.yaml`](/Users/deniszm/novatalks/nova.ci/.github/workflows/ci-build-ntk-on-push-tags-build.yaml): build and publish container images on `build*` tags
- [`ci-build-ntk-on-push-direct-to-protected-branches.yaml`](/Users/deniszm/novatalks/nova.ci/.github/workflows/ci-build-ntk-on-push-direct-to-protected-branches.yaml): build flow for direct pushes to protected branches
- [`ci-build-ntk-on-push-branches.yaml`](/Users/deniszm/novatalks/nova.ci/.github/workflows/ci-build-ntk-on-push-branches.yaml): build flow for selected branches
- [`ci-build-ntk-on-push-tags-run-test.yaml`](/Users/deniszm/novatalks/nova.ci/.github/workflows/ci-build-ntk-on-push-tags-run-test.yaml): integration test runner for `int-test` tags
- [`ci-build-ntk-on-push-tags-run-e2e.yaml`](/Users/deniszm/novatalks/nova.ci/.github/workflows/ci-build-ntk-on-push-tags-run-e2e.yaml): E2E test flow
- [`ci-e2e-tests-manual.yaml`](/Users/deniszm/novatalks/nova.ci/.github/workflows/ci-e2e-tests-manual.yaml): reusable Playwright E2E flow currently invoked by the switcher for tagged runs
- [`ci-build-ntk-on-push-tags-gh-deploy.yaml`](/Users/deniszm/novatalks/nova.ci/.github/workflows/ci-build-ntk-on-push-tags-gh-deploy.yaml): GitHub Pages deploy
- [`ci-build-ntk-on-push-tags-widget-build.yaml`](/Users/deniszm/novatalks/nova.ci/.github/workflows/ci-build-ntk-on-push-tags-widget-build.yaml): widget build flow
- [`ci-build-ntk-on-push-tags-mob-apk-build.yaml`](/Users/deniszm/novatalks/nova.ci/.github/workflows/ci-build-ntk-on-push-tags-mob-apk-build.yaml): mobile APK build
- [`ci-build-ntk-on-push-tags-mob-apk-build-public.yaml`](/Users/deniszm/novatalks/nova.ci/.github/workflows/ci-build-ntk-on-push-tags-mob-apk-build-public.yaml): public mobile APK build
- [`ci-build-ntk-on-push-tags-mob-pwa-build.yaml`](/Users/deniszm/novatalks/nova.ci/.github/workflows/ci-build-ntk-on-push-tags-mob-pwa-build.yaml): mobile PWA/SPA/CRM build flow
- [`ci-build-ntk-on-push-tags-flows-to-pub.yaml`](/Users/deniszm/novatalks/nova.ci/.github/workflows/ci-build-ntk-on-push-tags-flows-to-pub.yaml): publish botflow assets

## Internal actions

Current internal reusable actions in [`.github/actions`](/Users/deniszm/novatalks/nova.ci/.github/actions):

- [`action-cond/action.yml`](/Users/deniszm/novatalks/nova.ci/.github/actions/action-cond/action.yml): composite replacement for deprecated `haya14busa/action-cond`

`action-cond` exists to keep notifier workflows stable after GitHub Actions runner migration away from Node.js 20. It preserves the previous interface:

- input `cond`
- input `if_true`
- input `if_false`
- output `value`

This keeps notifier steps behavior-compatible while removing the dependency on an external JavaScript action.

## `novatalks.core` tag build behavior

In [`ci-build-ntk-on-push-tags-build.yaml`](/Users/deniszm/novatalks/nova.ci/.github/workflows/ci-build-ntk-on-push-tags-build.yaml), the `linter` job for `novatalks.core` installs dependencies once with `npm ci`, then runs targeted linting by tag:

- `build-engine` -> `npx eslint apps/engine libs/common libs/database --ext .ts`
- `build-reporting` -> `npx eslint apps/reporting libs/common libs/database --ext .ts`
- any other `build*` tag in `novatalks.core` -> fallback to `npm run lint`

The same workflow also selects the Dockerfile by tag:

- `build-engine` -> `docker/engine.Dockerfile`
- `build-reporting` -> `docker/reporting.Dockerfile`
- `build-restore-historical` -> `docker/restore-historical.Dockerfile`
- default -> `docker/server.Dockerfile`

The same workflow now also applies conservative build caching:

- `setup-node` enables `npm` cache only for repositories that use `npm ci` with `package-lock.json`
- container builds use a GHCR registry cache per image variant through `buildcache${IMAGE_SUFFIX}`
- `docker/build-push-action` runs with `pull: true`, so the current base image manifest is refreshed before build

## Trigger summary

Switcher rules currently cover these patterns:

- push to `master` or `development` for selected repositories
- push of tags containing `build`
- push of tags containing `int-test`
- push of tags for GitHub Pages, widget, mobile APK, mobile PWA, mobile SPA, CRM, and flows publishing
- push to branches containing `build-me-please`
- tagged invocation of the reusable Playwright E2E flow
