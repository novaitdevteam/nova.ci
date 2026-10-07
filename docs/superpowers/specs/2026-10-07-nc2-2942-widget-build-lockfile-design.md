# NC2-2942 — widget build from the lockfile, explicit PUBLIC_PATH (design)

Jira: [NC2-2942](https://sd.novait.com.ua/browse/NC2-2942), story
[NC2-2939](https://sd.novait.com.ua/browse/NC2-2939). Found while doing
[NC2-2941](https://sd.novait.com.ua/browse/NC2-2941) (`novatalks.chatwidget#121`); blocks
[NC2-2779](https://sd.novait.com.ua/browse/NC2-2779) (`novatalks.chatwidget#112`).

## Problem

`.github/workflows/ci-build-ntk-on-push-tags-widget-build.yaml`, step "Setup Components & Build":

```bash
curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
sudo apt-get update && sudo apt-get install yarn zip -y
yarn install
yarn build
```

1. **No lockfile.** `novatalks.chatwidget` has `package-lock.json` and no `yarn.lock`, so yarn ignores the lockfile
   and every build resolves the newest version inside each `package.json` range. Builds are not reproducible, any
   new in-range release (or a compromised one) ships unreviewed, and the dependency scanners (`deps-scan`,
   `npm audit`) read a different tree from the one shipped. Observed: production bundle had axios 1.20.0 / vue
   3.5.43 while the lockfile said 1.19.0 / 3.5.21, and dompurify twice (3.4.14 + 3.4.16).
2. **Third-party apt repository** added with the deprecated `apt-key`, only to install yarn.
3. **`PUBLIC_PATH` comes from the committed `.env`.** The team picks the target folder by committing a `.env` edit
   before pushing the tag `build` (history: `dev` → `qa1` → `v3` → `v2` → `dev` → `v3` since June 2026).
   `novatalks.chatwidget#112` untracks `.env` and makes a production build fail without `PUBLIC_PATH`; once it
   merges, **every CI widget build fails**.

## Design

### Tag format

`build-<target>[-<anything>]`, `<target>` ∈ `v2`, `v3`, `qa1`, `ka`, `dev` — the five folders under
`storage.novatalks.ai/static/widget/` that `.env` lists today. The team's habit changes from `build` to `build-v3`,
`build-qa1`, … The switcher is untouched: it already routes any widget tag containing `build`.

A missing or unknown target fails the run loudly (decided with the user — no silent default, because a default
would build for a production folder on a typo).

### `build-widget` job

1. **Prepare Vars** additionally derives the target from `GITHUB_REF_NAME` with an allowlist match,
   `^build-(v2|v3|qa1|ka|dev)(-|$)`. On a match it exports `TARGET` and `PUBLIC_PATH=/static/widget/$TARGET`
   (to `GITHUB_ENV` and outputs). The ref is never interpolated as-is: only the allowlisted capture is used, so the
   value is safe to launder through `GITHUB_ENV`. On no match `TARGET` stays empty.
2. **Delete Tag** — unchanged, so the tag is removed even when the target is wrong.
3. **Check target** (new, after Delete Tag): if `TARGET` is empty, `::error::` with the received tag and the five
   valid examples, `exit 1`.
4. **Setup Node**: `node-version-file: .nvmrc` instead of `node-version: "22"` (`.nvmrc` holds `22`).
5. **Build**:
   ```bash
   sudo apt-get update && sudo apt-get install -y zip   # self-hosted images ship no zip (runner-environment rule)
   npm ci --ignore-scripts --no-audit --no-fund
   npm run build
   ```
   with `PUBLIC_PATH` in the step `env:`. vue-cli's dotenv does not override an existing environment variable, so the
   explicit value wins over a committed `.env` (works before and after #112). `--ignore-scripts` keeps `snyk`'s
   postinstall from downloading a binary; the build needs no install script (verified in NC2-2941 with npm 11,
   which skips them).
6. **Check output** (new): `dist/index.html` must reference `"/static/widget/$TARGET/js/`; otherwise `::error::` and
   `exit 1` — proves `PUBLIC_PATH` actually reached the build.
7. **Names carry the target**: release/tag `NTK.CHATWIDGET_<release>_<ref>_<target>_<sha>`, zip
   `widget-release-<ref>-<target>-<sha>.zip`. Without it two builds of one commit for two folders collide in one
   release. Nothing parses these names (checked: only docs and human reports mention them).

### `sast-scan` and notifier

`RELEASE_TAG` and the notifier's download link follow the new name; `TARGET` becomes a `build-widget` output. The
success message gains a `Target: /static/widget/<target>` line. The failure branch is unchanged (it links the run,
where the `::error::` explains a bad tag).

### Unchanged

Switcher routing, Semgrep wrapper and its guards, permissions, pins, the `pull_request` gate on `sast-scan`.

## Edge cases

| Input                                   | Result                                                            |
| --------------------------------------- | ----------------------------------------------------------------- |
| `build-v3`, `build-qa1-NC2-2941`        | builds for that folder                                            |
| `build` (old habit), `build-v4`, `build-NC2-2940` | tag deleted, run fails: "unknown target … use build-v2/v3/qa1/ka/dev" |
| `rebuild-v3`, `x-build-v3`              | routed (contains `build`), no `^build-` match → fails loudly      |
| Branch without `package-lock.json`      | `npm ci` fails loudly (every chatwidget branch has one today)     |
| Branch where lockfile and `package.json` disagree | `npm ci` fails loudly — correct, the lockfile is the contract |
| Branch built before #121 merges         | ships its lockfile versions (older than today's yarn resolution) — reason #121 merges first |

## Verification

1. `./scripts/validate.sh` green (zizmor, actionlint, docs links, self-reference pins).
2. Live, with nova.ci's temporary-testing state (docs/reference/validation.md § Self-reference pins): switcher's
   widget call → `@NC2-2942`; a throwaway `novatalks.chatwidget` branch off `NC2-2941` whose caller points the
   switcher at `@NC2-2942`. While in place `validate.sh` is red by design.
   - `build-v3-…` → green; release `…_v3_…`; `dist/index.html` under `/static/widget/v3/`; bundle versions equal the
     lockfile (`axios` `VERSION="1.20.0"`, one `dompurify` `3.4.16`, vue `3.5.43`); Semgrep report attached;
     notifier link resolves.
   - `build-qa1-…` → paths under `/static/widget/qa1/`.
   - `build-…` with a bad target → run red with the error, tag gone.
   - Same `build-v3-…` on a branch with `.env` removed (#112's state) → green.
3. Revert both temporary refs to `@main`, delete the throwaway branch; `validate.sh` green again.

## Docs

`docs/pipeline/routing.md` (widget row: `build-<target>`), `docs/security/sast-dast.md` (release name),
`.agents/skills/nova-ci/SKILL.md` + `.claude/` mirror (widget tag format and naming), Outline (Ukrainian) via
`knowledge-capture`. The chatwidget's own build instructions change in a small chatwidget PR together with or after #112.

## Merge order

`novatalks.chatwidget#121` (NC2-2941) → this (nova.ci, merged by us after green CI and review) →
`novatalks.chatwidget#112` (NC2-2779).
