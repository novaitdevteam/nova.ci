# NC2-2942 — widget build from the lockfile, explicit PUBLIC_PATH — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The chat widget builds with `npm ci` from its lockfile, for a target folder named in the tag (`build-<target>`), with `PUBLIC_PATH` set by the workflow.

**Architecture:** All behaviour lives in `build-widget` of `ci-build-ntk-on-push-tags-widget-build.yaml`. Prepare Vars derives the target through an allowlist and folds it into `SHORT_REF_NAME`, so every downstream name (release, zip, Semgrep report, notifier link) carries it with no further edits. A check step after Delete Tag fails loudly on a missing target; the build step installs from the lockfile and asserts the output paths.

**Tech Stack:** GitHub Actions reusable workflow, bash, `actions/setup-node`, vue-cli build in `novatalks.chatwidget`; `./scripts/validate.sh` (YAML, zizmor, actionlint, docs links, self-reference pins).

**Spec:** `docs/superpowers/specs/2026-10-07-nc2-2942-widget-build-lockfile-design.md`

## Global Constraints

- Targets: exactly `v2`, `v3`, `qa1`, `ka`, `dev`; `PUBLIC_PATH=/static/widget/<target>`.
- Tag match: `^build-(v2|v3|qa1|ka|dev)(-|$)`; no match → `::error::`, `exit 1`, after the tag is deleted.
- Install: `npm ci --ignore-scripts --no-audit --no-fund`; build: `npm run build`; Node from `.nvmrc`.
- Never interpolate the ref as-is: only the allowlisted capture is used.
- Pins stay SHA-pinned; permissions unchanged; nova.ci self-references end on `@main`.
- Merge order: `novatalks.chatwidget#121` → this PR → `novatalks.chatwidget#112`. **Do not merge before #121 is merged.**

## Review Focus

1. Old habit tag `build` → run fails with a message naming the five valid tags, and the tag is gone. Pinned in Task 1 step 1 (case table) and Task 3 step 4 (live).
2. Tag with extra suffix (`build-qa1-NC2-2941`) → target `qa1`. Pinned in Task 1 step 1.
3. Look-alike tags (`build-v33`, `build-qa`, `build-v3x`, `xbuild-v3`) → no match, fail. Pinned in Task 1 step 1.
4. Branch without a tracked `.env` (state after #112) → build still gets `PUBLIC_PATH`. Pinned in Task 3 step 5.
5. `PUBLIC_PATH` not reaching the build (e.g. a future `.env` override) → output check fails the run instead of shipping wrong paths. Pinned in Task 1 step 4 (assertion) and Task 3 steps 2–3 (paths verified).

---

### Task 1: `build-widget` job

**Files:**
- Modify: `.github/workflows/ci-build-ntk-on-push-tags-widget-build.yaml` (build-widget: outputs, Prepare Vars, new Check target, Setup NODEJS, Setup Components & Build; notifier success message)

**Interfaces:**
- Produces: `steps.prep.outputs.TARGET`, job output `TARGET`; `SHORT_REF_NAME` now `<ref>_<target>`.

- [ ] **Step 1: Case table against the current Prepare Vars (RED)**

```bash
mkdir -p /tmp/nc2942 && cat > /tmp/nc2942/prep-cases.sh <<'EOF'
#!/usr/bin/env bash
# Runs the workflow's own Prepare Vars script for each tag and checks TARGET / PUBLIC_PATH / SHORT_REF_NAME.
set -u
wf=.github/workflows/ci-build-ntk-on-push-tags-widget-build.yaml
script="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"]["build-widget"]["steps"].find { |s| s["id"] == "prep" }["run"]' "$wf")"
fail=0
check() { # tag expected_target
  local d; d="$(mktemp -d)"
  GITHUB_REPOSITORY=novaitdevteam/novatalks.chatwidget GITHUB_SHA=0123456789abcdef GITHUB_REF_TYPE=tag \
  GITHUB_REF_NAME="$1" BASE_REF=refs/heads/NC2-2941 GITHUB_ENV="$d/env" GITHUB_OUTPUT="$d/out" \
    bash -euo pipefail -c "$script" >/dev/null 2>&1 || { echo "FAIL $1: prep script exited non-zero"; fail=1; return; }
  local t p r
  t="$(grep -s '^TARGET=' "$d/out" | cut -d= -f2-)"; p="$(grep -s '^PUBLIC_PATH=' "$d/env" | cut -d= -f2-)"; r="$(grep -s '^SHORT_REF_NAME=' "$d/out" | cut -d= -f2-)"
  if [[ "$t" != "$2" ]]; then echo "FAIL $1: TARGET='$t' want '$2'"; fail=1; return; fi
  if [[ -n "$2" && ( "$p" != "/static/widget/$2" || "$r" != "NC2-2941_$2" ) ]]; then echo "FAIL $1: PUBLIC_PATH='$p' SHORT_REF_NAME='$r'"; fail=1; return; fi
  echo "ok   $1 -> '${t}'"
}
for t in v2 v3 qa1 ka dev; do check "build-$t" "$t"; done
check build-qa1-NC2-2941 qa1
check build-v3-rc1 v3
for bad in build build- build-v33 build-qa build-v3x build-V3 xbuild-v3 build-NC2-2940 'build-v3$(id)'; do check "$bad" ""; done
exit $fail
EOF
chmod +x /tmp/nc2942/prep-cases.sh && /tmp/nc2942/prep-cases.sh
```
Expected: FAIL lines for every valid tag (`TARGET='' want 'v3'` …) — the current script has no target logic. Exit 1.

- [ ] **Step 2: Prepare Vars derives the target**

Add `TARGET: ${{ steps.prep.outputs.TARGET }}` to `build-widget.outputs`. In Prepare Vars, replace the last line (`echo "SHORT_REF_NAME=${short_ref_name}" | tee …`) with:

```bash
          # The target folder comes from the tag, through an allowlist only: build-<target>[-anything].
          # No match leaves TARGET empty; "Check target" fails the run after the tag is deleted.
          target=""
          if [[ "${GITHUB_REF_NAME}" =~ ^build-(v2|v3|qa1|ka|dev)(-|$) ]]; then
            target="${BASH_REMATCH[1]}"
            echo "PUBLIC_PATH=/static/widget/${target}" >> "$GITHUB_ENV"
            # Carry the target into every name built from SHORT_REF_NAME (release, zip, report, link).
            short_ref_name="${short_ref_name}_${target}"
          fi
          echo "TARGET=${target}" | tee -a "$GITHUB_ENV" "$GITHUB_OUTPUT"
          echo "SHORT_REF_NAME=${short_ref_name}" | tee -a "$GITHUB_ENV" "$GITHUB_OUTPUT"
```

- [ ] **Step 3: Case table (GREEN)**

Run: `/tmp/nc2942/prep-cases.sh`
Expected: 16 `ok` lines, exit 0.

- [ ] **Step 4: Check target, Node, build from the lockfile, output assertion**

After `Delete Tag`, insert:

```yaml
      - name: Check target
        run: |
          if [[ -z "${TARGET}" ]]; then
            echo "::error title=Unknown widget target::Tag '${GITHUB_REF_NAME}' names no target. Push build-v2, build-v3, build-qa1, build-ka or build-dev (an optional -suffix is allowed). The tag has been deleted."
            exit 1
          fi
          echo "Building for PUBLIC_PATH=${PUBLIC_PATH}"
```

(`GITHUB_REF_NAME` is a runner env var, not a template expansion; `TARGET`/`PUBLIC_PATH` come from `GITHUB_ENV` set by the allowlist.)

In `💿 Setup NODEJS`, replace `node-version: "22"` with `node-version-file: .nvmrc`.

Replace the `Setup Components & Build` run block with:

```bash
          # Self-hosted images ship no zip (runner-environment rule); yarn is gone — the lockfile is the contract.
          sudo apt-get update && sudo apt-get install -y zip
          npm ci --ignore-scripts --no-audit --no-fund
          npm run build
          # PUBLIC_PATH must have reached the build: every asset path in index.html is under the target folder.
          if ! grep -q "\"${PUBLIC_PATH}/js/" dist/index.html; then
            echo "::error title=Wrong asset paths::dist/index.html does not reference ${PUBLIC_PATH}/js/ — PUBLIC_PATH did not reach the build."
            exit 1
          fi
          zip -r ./widget-release-"${SHORT_REF_NAME}"-"${SHORT_SHA}".zip ./dist
```

Check the chatwidget output format first: `grep -o 'src="[^"]*js/widget.js"' ~/novatalks/novatalks.chatwidget/dist/index.html` after a `PUBLIC_PATH=/static/widget/v3 npm run build` there → `src="/static/widget/v3/js/widget.js"`. If the real `src` differs in shape (quotes, a missing slash), adapt the assertion to the real output — never the path.

In the notifier's `if_true` message, after the Download Link line, add:

```
            Target: /static/widget/${{ needs.build-widget.outputs.TARGET }}
```

- [ ] **Step 5: Validate**

Run: `./scripts/validate.sh > /tmp/nc2942/validate.log 2>&1; echo $?; tail -3 /tmp/nc2942/validate.log`
Expected: `0`, `VALIDATION OK` (zizmor clean — no new template injection; actionlint clean).

Run: `/tmp/nc2942/prep-cases.sh` again → 16 ok.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/ci-build-ntk-on-push-tags-widget-build.yaml
git commit -m "feat(NC2-2942): build the widget from its lockfile for a target named in the tag" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Docs

**Files:**
- Modify: `docs/pipeline/routing.md:21` — widget row: tag `build-<target>` (`v2`, `v3`, `qa1`, `ka`, `dev`), `build` alone fails.
- Modify: `docs/security/sast-dast.md:995` — release name `NTK.CHATWIDGET_<release>_<ref>_<target>_<sha>`.
- Modify: `.agents/skills/nova-ci/references/sast-and-deps-scan.md:48` and `.claude/skills/nova-ci/references/sast-and-deps-scan.md` (mirror) — same name.
- Modify: `.agents/skills/nova-ci/SKILL.md:68` and `.claude/skills/nova-ci/SKILL.md` (mirror) — one sentence: chat widget builds `npm ci` from the lockfile, target from `build-<target>`, `PUBLIC_PATH` set by the workflow.
- Modify: `docs/superpowers/specs/2026-10-07-nc2-2942-widget-build-lockfile-design.md` — zip name is `widget-release-<ref>_<target>-<sha>.zip` (target folded into `SHORT_REF_NAME`), notifier gains the Target line.

- [ ] **Step 1:** Make the edits above (wording in the files' existing style).
- [ ] **Step 2:** Run `./scripts/validate.sh` → `VALIDATION OK` (docs links and skill mirror check).
- [ ] **Step 3:** Commit `docs(NC2-2942): widget build tag format and release naming` with the Co-Authored-By line.

---

### Task 3: Live verification (temporary testing state, reverted in step 7)

- [ ] **Step 1: Temporary pins**
  - nova.ci: in `ci-build-trigger-switcher.yaml:435` change the widget call to `…widget-build.yaml@NC2-2942`; commit `test(NC2-2942): TEMP pin widget build to branch`; `git push -u origin NC2-2942`. (`validate.sh` is red now — by design.)
  - chatwidget: `git switch -c ci/nc2942-test origin/NC2-2941`; in `.github/workflows/ci-build-trigger.yaml` change `ci-build-trigger-switcher.yaml@main` → `@NC2-2942`; commit; push.
- [ ] **Step 2: `build-v3`** — `git tag build-v3-nc2942 && git push origin build-v3-nc2942`. Expected: run green; release `NTK.CHATWIDGET_2026_R4_ci-nc2942-test_v3_<sha8>` with `widget-release-ci-nc2942-test_v3-<sha8>.zip` and the Semgrep report; in the zip `dist/index.html` has `/static/widget/v3/js/`; `chunk-vendors.js` has `VERSION="1.20.0"`, one `.version="3.4.16"`, `"3.5.43"` (lockfile versions); job log shows `npm ci`, no yarn; notifier text has `Target: /static/widget/v3`.
- [ ] **Step 3: `build-qa1`** — tag `build-qa1-nc2942`. Expected: green, `dist/index.html` under `/static/widget/qa1/`, release name `…_qa1_…`.
- [ ] **Step 4: Bad tag (Review Focus 1)** — tag `build`. Expected: run red at `Check target` with the error naming the five tags; `git ls-remote --tags origin build` empty afterwards; no release created.
- [ ] **Step 5: No `.env` (Review Focus 4)** — `git switch -c ci/nc2942-test-noenv origin/NC2-2779`, apply the same caller change, push, tag `build-v3-nc2942-noenv`. Expected: green; paths under `/static/widget/v3/`.
- [ ] **Step 6: Clean up test artefacts** — delete the test releases (`gh release delete <tag> --cleanup-tag -y` for each `…ci-nc2942-test…`) and both throwaway branches (`git push origin --delete ci/nc2942-test ci/nc2942-test-noenv`).
- [ ] **Step 7: Revert the nova.ci pin** — `git revert --no-edit <TEMP commit>` (or edit back to `@main`), push. Run `./scripts/validate.sh` → `VALIDATION OK`.

---

### Task 4: Review, PR, merge gate, Jira

- [ ] **Step 1:** `ponytail:ponytail-review` and `/code-review` on `git diff origin/main...NC2-2942`; `/security-review` because the change touches a ref-derived value. Drop any finding that would weaken a `.claude/rules/` invariant.
- [ ] **Step 2:** `gh pr create --base main` titled `NC2-2942 · widget: build from the lockfile, target from build-<target>` — body: problem (3 points), design, the case table output, live results (links to the runs), merge order. Not draft: no product QA needed; the live runs are the verification.
- [ ] **Step 3:** Wait for `ci-self-validate` green.
- [ ] **Step 4: Merge gate** — merge (`gh pr merge --squash`, after the user says so) **only once `novatalks.chatwidget#121` is merged**; until then the PR stays open and ready.
- [ ] **Step 5:** Jira NC2-2942 comment: what changed and why; how the team builds now (`build-v3`, …, `build` fails); test evidence; merge order and state. After merge: comment on NC2-2779 that the blocker is gone; post the new tag format to the team (the notifier/Jira comment is the announcement).
