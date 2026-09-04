#!/usr/bin/env bash
#
# Validation harness for the nova.ci repository.
#
# Runs every check the agent/human docs reference, in one place:
#   - YAML parse of all reusable workflows and composite actions
#   - whitespace check (git diff --check)
#   - .agents <-> .claude skill mirror sync
#   - docs assets (every page has a diagram; every referenced asset exists)
#   - ci-build-create-runner.sh scenario self-check (offline, curl stubbed)
#   - secret-scan scan.sh scenario self-check (git fixtures, pinned gitleaks)
#   - SAST scan.sh scenario self-check (docker stubbed)
#   - dependency scan.sh scenario self-check (docker stubbed for OSV-Scanner; Trivy JSON
#     read from a fixture file)
#   - scanner invocation guard (no workflow may run Gitleaks, Semgrep or OSV-Scanner itself)
#   - notifier transport guard (no workflow may call the chat APIs directly)
#   - actionlint (when installed)
#
# Usage: ./scripts/validate.sh   (works from any cwd; resolves repo root itself)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

fail=0
section() { printf '\n=== %s ===\n' "$1"; }

section "YAML: reusable workflows and composite actions"
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f); puts "OK #{f}" }' \
  .github/workflows/*.yaml .github/actions/*/action.yml

section "Whitespace (git diff --check)"
if git rev-parse --git-dir >/dev/null 2>&1; then
  if git diff --check; then
    echo "OK: no whitespace errors in the working tree"
  else
    echo "ERROR: whitespace problems reported by git diff --check"
    fail=1
  fi
else
  echo "skip: not a git repository"
fi

section "Skill mirror (.agents vs .claude)"
if diff -q .agents/skills/nova-ci/SKILL.md .claude/skills/nova-ci/SKILL.md >/dev/null; then
  echo "OK: .agents and .claude skill copies are identical"
else
  echo "ERROR: .agents/skills/nova-ci/SKILL.md and .claude/skills/nova-ci/SKILL.md differ"
  echo "       keep the canonical .agents copy and its .claude mirror in sync"
  fail=1
fi

section "Documentation assets"
# Three rules that started as prose in CLAUDE.md. Prose is exactly what got skipped when
# docs/secret-detection.md was added without a diagram, so they are checks now.
#
# In Ruby, not Bash: the natural shell form needs a `case` inside a `$( ... )`, and bash
# 3.2 - which macOS still ships - mis-parses the pattern's `)` as closing the
# substitution. Ruby is already required above for the YAML parse.
if ruby -e '
  fail_count = 0

  # 1. every page under docs/ opens with a diagram from assets/readme/
  Dir.glob("docs/**/*.md").sort.each do |page|
    next if File.basename(page) == "README.md"
    next if page.include?("docs/superpowers/")   # specs and plans are records, not pages
    next if File.read(page).include?("assets/readme/")
    puts "       #{page}"
    fail_count += 1
  end
  abort "ERROR: these pages have no assets/readme/ diagram (CLAUDE.md, Editing style)" if fail_count > 0
  puts "OK: every docs page embeds a diagram"

  # 2. every locally referenced asset resolves - a renamed file is an invisible diff
  (Dir.glob("docs/**/*.md") + ["README.md"]).sort.each do |md|
    # The lookbehind is load-bearing: an unanchored src=" also matches the tail of any
    # identifier ending in "src", so a shell variable like zap_conf_src="..." in a fenced
    # code block was read as an HTML attribute and failed the whole run.
    File.read(md).scan(/(?<![-\w])src="([^"]+)"/).flatten.each do |ref|
      next if ref =~ %r{\A(https?:|#)}
      target = File.expand_path(ref, File.dirname(md))
      next if File.exist?(target)
      puts "       #{md} -> #{ref}"
      fail_count += 1
    end
  end
  abort "ERROR: these asset references do not resolve" if fail_count > 0
  puts "OK: every referenced asset resolves"

  # 3. below 18 SVG units a label is unreadable at GitHub content width
  Dir.glob("assets/readme/*.svg").sort.each do |svg|
    small = File.read(svg).scan(/font-size="(\d+)"/).flatten.map(&:to_i).select { |n| n < 18 }
    next if small.empty?
    puts "       #{svg} uses font-size #{small.uniq.sort.join(", ")}"
    fail_count += 1
  end
  abort "ERROR: these assets use font-size below 18 - unreadable at 900px" if fail_count > 0
  puts "OK: no asset drops below font-size 18"
'; then
  :
else
  fail=1
fi

section "Runner script self-check"
# ci-build-create-runner.sh decides whether CI provisions a VM, so its branches get a
# real regression net: the harness stubs curl and asserts the emitted $GITHUB_OUTPUT.
if command -v jq >/dev/null 2>&1; then
  if out="$(./scripts/test-create-runner.sh 2>&1)"; then
    echo "OK: all ci-build-create-runner.sh scenarios passed"
  else
    printf '%s\n' "$out"
    echo "ERROR: ci-build-create-runner.sh self-check failed"
    fail=1
  fi
else
  echo "skip: jq not installed"
fi

section "Secret scan self-check"
# scan.sh decides whether a pull request may merge, so its branches get the same
# treatment as the runner script: real git fixtures, the pinned gitleaks binary, and
# an assertion per decision branch (including that findings stay redacted).
# Exit 99 means the harness could not get a gitleaks binary. Reporting that as OK is
# the same silent-pass bug scan.sh guards against, so keep the three cases apart.
set +e
out="$(./scripts/test-secret-scan.sh 2>&1)"
scan_rc=$?
set -e
case "$scan_rc" in
  0)
    printf '%s\n' "$out" | tail -1
    echo "OK: all scan.sh scenarios passed"
    ;;
  99)
    printf '%s\n' "$out" | grep '^skip:' | sed 's/^/       /'
    echo "skip: scan.sh scenarios not run (CI always runs them on linux/x86_64)"
    ;;
  *)
    printf '%s\n' "$out"
    echo "ERROR: scan.sh self-check failed"
    fail=1
    ;;
esac

section "Secret-echo guard self-check"
# guard-secret-echo.sh runs as a PreToolUse hook and can refuse an agent's command, so a
# false positive is not the safe side of the trade — it teaches people to bypass the
# check. Both directions are asserted: the dumps it must block, and the redacted reads,
# `open(` calls and unrelated `tail -1`s it must not.
if out="$(./scripts/guard-secret-echo.sh --self-test 2>&1)"; then
  printf '%s\n' "$out" | tail -1
  echo "OK: all secret-echo guard scenarios passed"
else
  printf '%s\n' "$out"
  echo "ERROR: guard-secret-echo.sh self-check failed"
  fail=1
fi

section "SAST scan self-check"
# Semgrep's scan.sh decides whether a build reports findings, a clean scan or a broken
# scanner, and conflating the last two is the failure this guard exists to prevent.
# The harness stubs docker, so it needs no image and no network.
if command -v jq >/dev/null 2>&1; then
  if out="$(./scripts/test-sast-scan.sh 2>&1)"; then
    printf '%s\n' "$out" | tail -1
    echo "OK: all semgrep scan.sh scenarios passed"
  else
    printf '%s\n' "$out"
    echo "ERROR: semgrep scan.sh self-check failed"
    fail=1
  fi
else
  echo "skip: jq not installed"
fi

section "Dependency scan self-check"
# deps-scan's scan.sh decides whether a build reports declared-dependency findings, a
# clean scan, "no manifests found", or a broken scanner — and the four have to stay
# distinct the same way Semgrep's do. The harness stubs docker (OSV-Scanner only; Trivy
# is read from a plain JSON file, never invoked here) so it needs no image and no network.
if command -v jq >/dev/null 2>&1; then
  if out="$(./scripts/test-deps-scan.sh 2>&1)"; then
    printf '%s\n' "$out" | tail -1
    echo "OK: all deps-scan scan.sh scenarios passed"
  else
    printf '%s\n' "$out"
    echo "ERROR: deps-scan scan.sh self-check failed"
    fail=1
  fi
else
  echo "skip: jq not installed"
fi

section "DAST target table self-check"
# targets.sh is the one per-repository table sourced by dast-scan, api-scan and (later)
# the live-baseline dispatch. A wrong value is not a crash: it is a scan of the wrong
# port that finds nothing and reports it clean, so every arm's shape is asserted here
# and the default arm is asserted to fail rather than guess.
if out="$(./scripts/test-dast-targets.sh 2>&1)"; then
  printf '%s\n' "$out" | tail -1
  echo "OK: all DAST target table scenarios passed"
else
  printf '%s\n' "$out"
  echo "ERROR: DAST target table self-check failed"
  fail=1
fi

section "DAST scan self-check"
# The four DAST outcomes must stay distinct: a build that could not boot its own image
# is not a clean scan. The harness stubs docker and curl, so no image is pulled. Unlike
# the SAST self-check above, nothing here parses JSON, so there is no jq dependency to
# gate on — gating it anyway would silently skip a check that has no reason to skip.
if out="$(./scripts/test-dast-scan.sh 2>&1)"; then
  printf '%s\n' "$out" | tail -1
  echo "OK: all dast scan.sh scenarios passed"
else
  printf '%s\n' "$out"
  echo "ERROR: dast scan.sh self-check failed"
  fail=1
fi

section "DAST API scan self-check"
# The authenticated api-scan action shares the four-outcome contract with the baseline
# but adds one precondition class of its own — boot, migrate, seed, log in, fetch the
# spec — each its own loud skip. docker and curl are stubbed, same as the baseline
# check above; no image, no network, no real ZAP.
if out="$(./scripts/test-dast-api-scan.sh 2>&1)"; then
  printf '%s\n' "$out" | tail -1
  echo "OK: all dast-api scan.sh scenarios passed"
else
  printf '%s\n' "$out"
  echo "ERROR: dast-api scan.sh self-check failed"
  fail=1
fi

section "Scanner invocation"
# The install-and-scan logic lives in .github/actions/gitleaks only. A workflow that
# calls the binary or the upstream action itself is the copy-paste that action exists
# to prevent, and would bypass the central config and the redaction flag.
# Two shapes count as invoking it: running the binary (a gitleaks subcommand in a run
# block) or using some other gitleaks action. Referencing the step - `id: gitleaks`,
# `steps.gitleaks.outputs.*` - is not an invocation, so match the invocation shapes
# rather than the bare word. Both greps use -E: the allowlist needs an alternation that
# ends in `$`, and that combination did not behave the same under BRE here.
offenders="$(grep -nE 'gitleaks +(git|dir|detect|protect|stdin)\b|uses:.*gitleaks' .github/workflows/*.yaml \
  | grep -vE 'uses:.*/\.github/actions/gitleaks(@|$)' \
  | grep -v ':[0-9]*: *#' || true)"
if [ -z "$offenders" ]; then
  echo "OK: every workflow scans through .github/actions/gitleaks"
else
  printf '%s\n' "$offenders" | sed 's/^/       /'
  echo "ERROR: these lines invoke Gitleaks directly; use .github/actions/gitleaks"
  fail=1
fi

# Same argument as Gitleaks: the pin, the canary guard and the harness all live in
# .github/actions/semgrep, and an inline `docker run semgrep` bypasses all three at once.
# `ci` is as real a subcommand as `scan` for gating purposes, so both are covered.
# The docker-image pattern names the actual images rather than the bare word
# "semgrep", so the sanctioned `uses: .../.github/actions/semgrep@main` line, which
# also contains that word, does not trip it.
# Residual gap (shared with the Gitleaks guard above, not fixed here): this is a
# per-line grep, so a `docker run` invocation split across a line-broken YAML block
# scalar is not caught. It stops careless copy-paste, not a determined bypass.
semgrep_offenders="$(grep -nE 'semgrep +(scan|ci)\b|uses:.*semgrep|docker +run.*(semgrep/semgrep|returntocorp/semgrep)' .github/workflows/*.yaml \
  | grep -vE 'uses:.*/\.github/actions/semgrep(@|$)' \
  | grep -v ':[0-9]*: *#' || true)"
if [ -z "$semgrep_offenders" ]; then
  echo "OK: every workflow scans through .github/actions/semgrep"
else
  printf '%s\n' "$semgrep_offenders" | sed 's/^/       /'
  echo "ERROR: these lines invoke Semgrep directly; use .github/actions/semgrep"
  fail=1
fi

# Same argument again: the pin and the harness live in .github/actions/dast (baseline)
# and .github/actions/dast-api (authenticated), and a workflow that shells out to
# zap-baseline.py, zap-full-scan.py or zap-api-scan.py directly, or uses a third-party
# zaproxy action, bypasses the digest pin and the not-run/error distinction. Narrower
# than the Semgrep guard above on purpose-not-yet-done: it does NOT match a bare
# `docker run ghcr.io/zaproxy/zaproxy`, because ZAP is normally driven through one of the
# three scripts above. Say so rather than claim coverage this pattern does not have - a
# guard described as stronger than it is, is worse than an honestly narrow one.
#
# Two deliberate exemptions from the blanket check below, same shape of carve-out as
# ci-self-validate.yaml gets elsewhere in this file. Both are meta/ops workflows, not a
# product build, and both still pin the same digest and call the shared zap_tally_parse
# from dast/dast-common.sh, so the drift-dangerous parsing logic is not copied:
#
#   - ci-dast-live-baseline.yaml: a workflow_dispatch one-off that points the pinned ZAP
#     image at a single allowlisted live URL, not at a product image, so neither
#     .github/actions/dast (boots an image) nor .github/actions/dast-api (boots + logs
#     in) applies. It has only the one path, so a plain file exclusion is the whole
#     story — nothing else in it could ever call ZAP directly.
#   - ci-dast-pentest.yaml has two paths, and only one of them — `target: live` — may
#     call ZAP directly; `target: ephemeral` must keep routing through dast/dast-api.
#     A file-path exclusion cannot express "this file except these lines", so instead
#     of exempting it from the blanket check, it is exempted and separately
#     count-checked below: exactly one direct-invocation line is allowed, the live
#     path's zap-full-scan.py call. A second line is a direct call that landed
#     somewhere it should not have — most likely the ephemeral path regressing — and
#     fails the build.
#
# Do not widen either exemption to a third file.
zap_offenders="$(grep -nE 'zap-baseline\.py|zap-full-scan\.py|zap-api-scan\.py|uses:.*zaproxy' .github/workflows/*.yaml \
  | grep -vE '^\.github/workflows/ci-dast-live-baseline\.yaml:|^\.github/workflows/ci-dast-pentest\.yaml:' \
  | grep -v ':[0-9]*: *#' || true)"
if [ -z "$zap_offenders" ]; then
  echo "OK: no workflow runs ZAP directly"
else
  printf '%s\n' "$zap_offenders" | sed 's/^/       /'
  echo "ERROR: these lines invoke ZAP directly; use .github/actions/dast or .github/actions/dast-api"
  fail=1
fi

# The count assertion ci-dast-pentest.yaml's exemption above depends on: exactly one
# direct ZAP invocation line, the target: live path's zap-full-scan.py call. This is
# what keeps the ephemeral path honestly covered despite the file-level exemption two
# blocks up — it does not (and cannot, from a line count alone) confirm that the one
# line is in the live path specifically, only that a second one has not appeared
# somewhere it should not have.
#
# Deliberately narrower than the blanket pattern above: anchored on the script name as
# the line's first token (`^[[:space:]]*zap-*\.py\b`), not a bare substring match. A
# substring match also catches this same file's own `scanner_error "zap-full-scan.py
# exited ${zap_rc}"` — text naming the script in an error message, not a second
# invocation — and would make the count permanently 2, which is not the constraint
# being asserted. The real invocation is a continuation line of the `docker run ... \`
# command above it and so starts with the script name; the error-message mention never
# does. `[[:space:]]`, not `\s`, for the same GNU-vs-BSD reason the tally-line anchor in
# dast-common.sh is ANSI-C quoted — GNU grep's `\s` is a non-portable extension, and
# this file is meant to run identically on a contributor's Mac and on the Linux runner.
# -H forces the file:line: prefix grep otherwise omits on a single-file match — without
# it the comment-exclusion pattern below (built for the "path:line:content" shape the
# multi-file glob above produces) silently matches nothing, and every mention of
# zap-full-scan.py in a comment counts as an offending line too.
pentest_zap_lines="$(grep -HnE '^[[:space:]]*zap-(baseline|full-scan|api-scan)\.py\b|uses:.*zaproxy' .github/workflows/ci-dast-pentest.yaml \
  | grep -v ':[0-9]*: *#' || true)"
pentest_zap_count=0
[ -n "$pentest_zap_lines" ] && pentest_zap_count="$(printf '%s\n' "$pentest_zap_lines" | wc -l | tr -d ' ')"
if [ "$pentest_zap_count" -eq 1 ]; then
  echo "OK: ci-dast-pentest.yaml invokes ZAP directly exactly once (the target: live path)"
else
  printf '%s\n' "$pentest_zap_lines" | sed 's/^/       /'
  echo "ERROR: ci-dast-pentest.yaml has ${pentest_zap_count} direct ZAP invocation line(s), expected exactly 1 (the target: live path's zap-full-scan.py call) — a direct call reached somewhere it should not have, most likely the target: ephemeral path"
  fail=1
fi

# The live path is a browser full scan and nothing else: no image to boot means no spec
# to drive zap-api-scan.py from and no token to inject. Without this rejection,
# `surface: api` ran the same anonymous zap-full-scan.py against the host root while the
# report banner, the job summary and the notification all said `api` — a mislabelled
# artifact, which is worse than a missing one. Asserted here rather than left to review
# because the label and the scan live in different steps of the file.
if grep -q 'target=live supports surface=browser only' .github/workflows/ci-dast-pentest.yaml; then
  echo "OK: ci-dast-pentest.yaml's live path rejects surface: api"
else
  echo "ERROR: ci-dast-pentest.yaml no longer rejects surface: api on the live path — a browser crawl would be reported as an API scan"
  fail=1
fi

# Same argument again for OSV-Scanner: the pinned digest and the exit-code guard (the
# silent-zero trap documented at the top of deps-scan/scan.sh) live in
# .github/actions/deps-scan only, and a workflow that runs `osv-scanner scan` or
# `docker run ghcr.io/google/osv-scanner` itself bypasses both. Trivy has no equivalent
# guard here on purpose — it is called directly in every Trivy job in this repository,
# deps-scan included, and there never was a "wrap it in an action" rule for it.
osv_offenders="$(grep -nE 'osv-scanner +scan\b|docker +run.*google/osv-scanner' .github/workflows/*.yaml \
  | grep -vE 'uses:.*/\.github/actions/deps-scan(@|$)' \
  | grep -v ':[0-9]*: *#' || true)"
if [ -z "$osv_offenders" ]; then
  echo "OK: every workflow scans through .github/actions/deps-scan"
else
  printf '%s\n' "$osv_offenders" | sed 's/^/       /'
  echo "ERROR: these lines invoke OSV-Scanner directly; use .github/actions/deps-scan"
  fail=1
fi

section "Notifier transport"
# The Telegram and Google Chat transport lives in .github/actions/notify only. A
# workflow that reaches either API itself is the copy-paste that action replaced.
# Passing the webhook to the action (gchat_webhook:) is the supported form; commented
# out code is not a live call.
offenders="$(grep -n 'api\.telegram\.org\|chat\.googleapis\.com\|telegram-action\|GC_NOTIFICATION_WEBHOOK' .github/workflows/*.yaml \
  | grep -v 'gchat_webhook:' \
  | grep -v ':[0-9]*: *#' || true)"
if [ -z "$offenders" ]; then
  echo "OK: no workflow reaches the chat APIs directly"
else
  printf '%s\n' "$offenders" | sed 's/^/       /'
  echo "ERROR: these lines reach Telegram or Google Chat directly; use .github/actions/notify"
  fail=1
fi

section "Self-reference pins"
# Every uses: that points back into nova.ci must pin @main. A branch ref here is a
# TEMPORARY testing state: it lets a product repo's test branch exercise unmerged CI,
# and it must never reach main, where it would make the pipeline reference a branch
# that no longer exists — or, worse, one that still does and has since moved.
#
# This check failing is not a bug. While a test ref is in place validate.sh is red on
# purpose, and that red is what makes the temporary state impossible to merge by
# accident. Restore the refs to @main and it goes green.
#
# Commented lines are skipped: the legacy branch-push route is kept commented, not
# deleted, and its ref is inert.
selfrefs="$(grep -nE 'uses: *novaitdevteam/nova\.ci/[^@]+@' .github/workflows/*.yaml \
  | grep -vE '@main([[:space:]]|$)' \
  | grep -v ':[0-9]*: *#' || true)"
if [ -z "$selfrefs" ]; then
  echo "OK: every nova.ci self-reference pins @main"
else
  printf '%s\n' "$selfrefs" | sed 's/^/       /'
  echo "ERROR: these lines pin a non-main nova.ci ref."
  echo "       If this is a deliberate test state, restore them to @main before merging."
  fail=1
fi

section "actionlint"
# actionlint is advisory by default: the repo's workflows carry a large pre-existing
# backlog of shellcheck-info / expression findings. We surface them but do not fail the
# harness on them, so the clean gates above stay meaningful. Set STRICT_ACTIONLINT=1 to
# enforce (use once the backlog is cleaned up).
if command -v actionlint >/dev/null 2>&1; then
  if out="$(actionlint 2>&1)"; then
    echo "OK: actionlint passed"
  elif [[ "${STRICT_ACTIONLINT:-0}" == "1" ]]; then
    printf '%s\n' "$out"
    echo "ERROR: actionlint reported problems (STRICT_ACTIONLINT=1)"
    fail=1
  else
    n="$(printf '%s\n' "$out" | grep -cE '\[[a-z-]+\]$' || true)"
    echo "WARN: actionlint reported ${n} finding(s) — advisory (pre-existing backlog)."
    echo "      Run 'actionlint' for details, or set STRICT_ACTIONLINT=1 to enforce."
  fi
else
  echo "skip: actionlint not installed (https://github.com/rhysd/actionlint)"
fi

echo
if [[ "$fail" -ne 0 ]]; then
  echo "VALIDATION FAILED"
  exit 1
fi
echo "VALIDATION OK"
