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
if command -v actionlint >/dev/null 2>&1; then
  if actionlint; then
    echo "OK: actionlint passed"
  else
    echo "ERROR: actionlint reported problems"
    fail=1
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
