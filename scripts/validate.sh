#!/usr/bin/env bash
#
# Validation harness for the nova.ci repository.
#
# Runs every check the agent/human docs reference, in one place:
#   - YAML parse of all reusable workflows and composite actions
#   - whitespace check (git diff --check)
#   - .agents <-> .claude skill mirror sync
#   - ci-build-create-runner.sh scenario self-check (offline, curl stubbed)
#   - secret-scan scan.sh scenario self-check (git fixtures, pinned gitleaks)
#   - Gitleaks invocation guard (no workflow may run the scanner itself)
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

section "Gitleaks invocation"
# The install-and-scan logic lives in .github/actions/gitleaks only. A workflow that
# calls the binary or the upstream action itself is the copy-paste that action exists
# to prevent, and would bypass the central config and the redaction flag.
offenders="$(grep -n 'gitleaks' .github/workflows/*.yaml \
  | grep -v 'actions/gitleaks' \
  | grep -v ':[0-9]*: *#' || true)"
if [ -z "$offenders" ]; then
  echo "OK: every workflow scans through .github/actions/gitleaks"
else
  printf '%s\n' "$offenders" | sed 's/^/       /'
  echo "ERROR: these lines invoke Gitleaks directly; use .github/actions/gitleaks"
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
