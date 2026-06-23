#!/usr/bin/env bash
#
# Validation harness for the nova.ci repository.
#
# Runs every check the agent/human docs reference, in one place:
#   - YAML parse of all reusable workflows and composite actions
#   - whitespace check (git diff --check)
#   - .agents <-> .claude skill mirror sync
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

section "YAML: reusable workflows"
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f); puts "OK #{f}" }' .github/workflows/*.yaml

section "YAML: composite actions"
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f); puts "OK #{f}" }' .github/actions/*/action.yml

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
