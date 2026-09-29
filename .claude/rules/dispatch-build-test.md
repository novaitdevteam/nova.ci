---
paths:
  - ".github/workflows/ci-build-trigger-switcher.yaml"
  - ".github/workflows/ci-build-ntk-*.yaml"
  - "docs/pipeline/routing.md"
  - "docs/pipeline/build-pipeline.md"
  - "docs/pipeline/notifications.md"
  - "docs/testing/tests.md"
  - "docs/getting-started/**"
---

# Dispatch, pull request, lint and test rules

Loaded when Claude Code reads a matching file; Codex and humans read it from the table in [`CLAUDE.md`](../../CLAUDE.md). Breaking one of these is a regression even when the workflow still parses.

**Dispatch**

- Keep dispatch logic centralized in `ci-build-trigger-switcher.yaml`, and build target interpretation centralized in `ci-build-ntk-on-push-tags-build.yaml`.
- `novatalks.flowrunner` builds from `./Dockerfile` at its repository root; it has no `docker/` directory for the default `docker/server.Dockerfile` arm to find. That is an arm in the build workflow's `Set Dockerfile path and image suffix` step, not a file move in the product repository.
- Do not edit product repository caller workflows unless the user explicitly asks.
- Keep the legacy branch-push build route (`call-external-on-pull-request-merged`) **commented, not deleted**. A bare `contains(head_commit.message, 'build')` matched ordinary prose and built images from feature branches. If it is ever revived, gate it on an explicit marker (e.g. `[build]`) and/or a branch allowlist.

**Pull requests**

- Pull request events run lint, unit tests, `secret-scan` and the switcher's inline `sast-scan` — no image, so no `build-image`, `trivy-scan`, `dast-scan`, `api-scan` or notifier; those stay gated on `github.event_name != 'pull_request'`.
- **Do not re-add `!github.event.pull_request.draft` to the pull request build routes.** It was removed deliberately: the product callers' `pull_request:` has no `types:`, so `ready_for_review` never arrives, and a draft later marked ready got no lint and no unit tests at all — reported as `skipped`, not red. `novatalks.core#217` sat open for a month that way. Keep `ready_for_review` in the action lists: inert today, correct if a caller ever subscribes.
- Never introduce real tag deletion for PR builds. Tag deletion stays limited to tag-triggered builds with an empty `build_target`, and uses `actions/github-script@v8` (`git.deleteRef`), not a third-party action.

**Lint and tests**

- Keep unit tests advisory and sequential after lint (`needs: [linter]`, `if: !cancelled()`) — one build occupies one runner.
- Keep `build-image` ungated on lint and unit results.
- Do **not** add `continue-on-error` to `unit-test` or `integration-tests`. The job must still report red when tests fail. (Their `Save Artifact` step carries it, and that is fine: a full artifact quota is not a test result.)
- Keep the unit gate backward-compatible: repos without a test plan resolve to a no-op success, reported as `⏭️ n/a`, never `✅`.
- Keep `npm run test:unit` and `npm run test:integration` as the canonical scripts. Do not replace them with raw `npx jest` and hand-assembled flags. The rule is that the command lives in the product repository's own `package.json`, not that the name is literal: `novatalks.flowrunner` has no `test:unit`, so its arm runs that repository's own `npm test`. Its install is two commands, not one — `npm ci` **and** `DATABASE_URL=postgresql://stub:stub@localhost:5432/stub npx prisma generate`: its specs import `PrismaService`, `@prisma/client` throws on import until the client is generated, and `prisma.config.ts` refuses to load without `DATABASE_URL` at all (generate never connects, so a stub is enough — and an obviously-fake one, since this repository is public).
- Keep the linter's `⏭️ n/a (no lint configured)` state, computed in `End Linter Step` from an empty resolved `lint_command`, exactly as the unit gate computes its own. `novatalks.flowrunner` has no linter at all — no eslint config, no `lint` script — so it gets a repository arm with no command rather than the generic yarn+eslint fallback, which would red every one of its builds on a missing eslint config. Reporting `✅` for zero checks is the same guard-that-measures-nothing this repository refuses everywhere else.
