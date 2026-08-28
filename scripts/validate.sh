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
#   - scanner invocation guard (no workflow may run Gitleaks or Semgrep itself)
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
    File.read(md).scan(/src="([^"]+)"/).flatten.each do |ref|
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
