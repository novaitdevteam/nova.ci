# NC2-2990: run nova.botflow's unit tests in the build gate

Ticket: [NC2-2990](https://sd.novait.com.ua/browse/NC2-2990). Product change:
[nova.botflow#368](https://github.com/novaitdevteam/nova.botflow/pull/368).

## Problem

The `unit-test` job's "Resolve test plan" step
(`.github/workflows/ci-build-ntk-on-push-tags-build.yaml:227`) has repository arms for
`novatalks.core` and `novatalks.flowrunner` only. `nova.botflow` falls through to `*) ;;`. Its
unit gate is therefore a no-op success, reported as `⏭️ n/a (no unit tests configured)`. Seen on
nova.botflow#368, run 38562759016.

nova.botflow does have a unit suite: its own `npm test` (Node's built-in `node --test`, with no
network and no services). NC2-2990 adds a regression test to that suite for a production incident.
At the moment the test never runs on a pull request.

## Goal

On nova.botflow pull requests and builds, the unit gate runs that repository's `npm test` and
reports `✅` or `❌`.

## Design

Add one arm to the "Resolve test plan" `case`, next to `novatalks.flowrunner`:

```bash
            nova.botflow)
              set_output install_command "npm ci"
              set_output node_cache "npm"
              set_output cache_dependency_path "package-lock.json"
              set_output unit_test_command "npm test"
              selected_unit_cmd="npm test"
              ;;
```

- **Install command.** `npm ci` with the npm cache keyed on `package-lock.json` is what the lint
  plan already uses for `nova.botflow` (`:118-123`). The same install is known to work on the
  runners.
- **Test command.** It lives in the product repository's `package.json`. This follows the existing
  rule (`.claude/rules/dispatch-build-test.md:35`) that flowrunner already uses with `npm test`.
- **Node version.** The job already sets up Node 24, and nova.botflow requires `>= 24`.
- **Unchanged.** Job wiring, `needs`, advisory status, `continue-on-error`, and the `⏭️ n/a` path
  for every other repository.

## Non-goals

- nova.botflow's `npm run test:queue` needs a reachable Redis, so it is not part of `npm test`.
- The tag-triggered test runner (`ci-build-ntk-on-push-tags-run-test.yaml`).

## Verification

- Run `./scripts/validate.sh` and get a green result: zizmor, token permissions and lint of the
  workflow.
- Rehearse the gate's exact commands on a clean checkout of nova.botflow#368 (`NC2-2990`) with
  Node 24: `npm ci && npm test` must pass, 42/42.
- After merge, re-run CI on nova.botflow#368. The PR's `Unit Tests` job must log
  `Selected unit test command: npm test` and `UNIT_CHECK=✅`.

## Documentation

- `docs/testing/tests.md` § Unit tests (build gate): add nova.botflow to the list of repositories
  with a test plan.
- `.claude/rules/dispatch-build-test.md:35`: name nova.botflow next to flowrunner as a repository
  whose arm runs its own `npm test`.
