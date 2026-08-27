#!/usr/bin/env bash
#
# Self-check for .github/actions/gitleaks/scan.sh.
#
# The script decides whether a pull request is allowed to merge, so every decision
# branch gets a scenario. It runs offline against throwaway git fixtures and the real
# pinned gitleaks binary — the version and checksum are read out of action.yml so the
# harness can never test a version CI does not run.
#
# The fixture credentials are assembled from halves at runtime, so no line of this
# file matches a gitleaks rule and nova.ci's own secret-scan stays green.
#
# Usage: ./scripts/test-secret-scan.sh
#
# Exit status: 0 all scenarios passed, 1 a scenario failed, 99 skipped (no gitleaks
# binary available). Callers must not read 99 as a pass.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION_DIR="$ROOT/.github/actions/gitleaks"
SCAN="$ACTION_DIR/scan.sh"
CONFIG="$ROOT/security/gitleaks/gitleaks.toml"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

# --- gitleaks binary -------------------------------------------------------------
# Take the pin straight from the action, so a bump there is what gets tested here.
VERSION="$(sed -n 's/.*GITLEAKS_VERSION: *"\([0-9.]*\)".*/\1/p' "$ACTION_DIR/action.yml" | head -1)"
SHA256="$(sed -n 's/.*GITLEAKS_SHA256: *"\([0-9a-f]*\)".*/\1/p' "$ACTION_DIR/action.yml" | head -1)"
[ -n "$VERSION" ] && [ -n "$SHA256" ] || { echo "ERROR: cannot read the gitleaks pin out of action.yml"; exit 1; }

sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

if [ -n "${GITLEAKS_BIN:-}" ] && [ -x "${GITLEAKS_BIN}" ]; then
    :
elif command -v gitleaks >/dev/null 2>&1; then
    GITLEAKS_BIN="$(command -v gitleaks)"
elif [ "$(uname -s)" = "Linux" ] && [ "$(uname -m)" = "x86_64" ]; then
    # The one platform whose checksum action.yml pins, so the only one we download.
    cache="${TMPDIR:-/tmp}/nova-ci-gitleaks-${VERSION}"
    mkdir -p "$cache"
    if [ ! -x "$cache/gitleaks" ]; then
        tarball="gitleaks_${VERSION}_linux_x64.tar.gz"
        curl -fsSL --retry 3 -o "$cache/$tarball" \
            "https://github.com/gitleaks/gitleaks/releases/download/v${VERSION}/${tarball}" \
            || { echo "skip: cannot download gitleaks ${VERSION} (offline?)"; exit 99; }
        got="$(sha_of "$cache/$tarball")"
        [ "$got" = "$SHA256" ] || { echo "ERROR: gitleaks ${VERSION} checksum mismatch"; echo "  action.yml: $SHA256"; echo "  downloaded: $got"; exit 1; }
        tar -xzf "$cache/$tarball" -C "$cache" gitleaks
        chmod +x "$cache/gitleaks"
    fi
    GITLEAKS_BIN="$cache/gitleaks"
else
    echo "skip: gitleaks not installed (brew install gitleaks) and no pinned build for $(uname -s)/$(uname -m)"
    exit 99
fi
export GITLEAKS_BIN
echo "using gitleaks: $GITLEAKS_BIN ($("$GITLEAKS_BIN" version 2>/dev/null || echo '?'), pin ${VERSION})"

# --- fixture credentials ---------------------------------------------------------
# Split so neither literal is a match on its own: "ghp_" is too short for the
# github-pat rule, and the body carries no key/token/secret keyword to trip
# generic-api-key.
P='ghp_'
B1='Xa9Qw3ZbT7yLmN2pRs8VdKcE1fGh4JiO6uPq'
B2='Zz1Yy2Xx3Ww4Vv5Uu6Tt7Ss8Rr9Qq0PpOoNn'   # 36 chars, same as B1: github-pat is length-exact
LEAK_ONE="${P}${B1}"
LEAK_TWO="${P}${B2}"

# --- fixture builder -------------------------------------------------------------
new_repo() {
    local dir="$WORK/$1"
    rm -rf "$dir"; mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email ci@novatalks.test
    git -C "$dir" config user.name "nova.ci harness"
    git -C "$dir" config commit.gpgsign false
    echo "$dir"
}
commit() { # commit <repo> <message> [file content...]
    local d="$1" m="$2"; shift 2
    git -C "$d" add -A
    git -C "$d" commit -q --allow-empty -m "$m"
}
at() { git -C "$1" rev-parse "${2:-HEAD}"; }

# --- runner ----------------------------------------------------------------------
# expect <name> <expected-exit> <repo> <event> [env assignments...]
expect() {
    local name="$1" want="$2" repo="$3" event="$4"; shift 4
    local summary="$WORK/summary.md" out
    : > "$summary"
    set +e
    out="$(cd "$repo" && env \
        GITLEAKS_BIN="$GITLEAKS_BIN" \
        GITLEAKS_CONFIG="${SCAN_CONFIG:-$CONFIG}" \
        GITLEAKS_VERSION="$VERSION" \
        GITLEAKS_LOG_FILE="$WORK/gitleaks.log" \
        GITHUB_STEP_SUMMARY="$summary" \
        GITHUB_REPOSITORY="novaitdevteam/fixture" \
        GITHUB_EVENT_NAME="$event" \
        GITHUB_SHA="$(at "$repo")" \
        PR_BASE_SHA="" PR_HEAD_SHA="" PR_NUMBER="1" PUSH_BEFORE="" \
        "$@" bash "$SCAN" 2>&1)"
    local got=$?
    set -e
    if [ "$got" -eq "$want" ]; then
        printf 'ok   %-56s exit=%s\n' "$name" "$got"
        pass=$((pass + 1))
    else
        printf 'FAIL %-56s exit=%s want=%s\n' "$name" "$got" "$want"
        printf '%s\n' "$out" | sed 's/^/       | /'
        fail=$((fail + 1))
    fi
    LAST_SUMMARY="$summary"
    LAST_OUT="$out"
}

assert_summary() { # assert_summary <name> <grep-pattern> [--absent]
    local name="$1" pat="$2" mode="${3:-present}"
    if grep -q -- "$pat" "$LAST_SUMMARY"; then
        if [ "$mode" = "--absent" ]; then
            printf 'FAIL %-56s summary must NOT contain %s\n' "$name" "$pat"; fail=$((fail + 1)); return
        fi
    elif [ "$mode" != "--absent" ]; then
        printf 'FAIL %-56s summary missing %s\n' "$name" "$pat"; fail=$((fail + 1)); return
    fi
    printf 'ok   %-56s\n' "$name"; pass=$((pass + 1))
}

echo
echo "=== pull request scenarios ==="

# Case 1 - a pull request with no credentials passes.
r="$(new_repo pr-clean)"
echo "hello" > "$r/app.js"; commit "$r" "base"
base="$(at "$r")"
echo "export const answer = 42" > "$r/app.js"; commit "$r" "feature"
expect "case 1: clean pull request" 0 "$r" pull_request PR_BASE_SHA="$base" PR_HEAD_SHA="$(at "$r")"
assert_summary "case 1: summary reports a clean scan" "No secrets detected"

# Case 2 - a credential added by the pull request fails.
r="$(new_repo pr-leak)"
echo "hello" > "$r/app.js"; commit "$r" "base"
base="$(at "$r")"
printf 'const token = "%s"\n' "$LEAK_ONE" > "$r/app.js"; commit "$r" "oops"
expect "case 2: pull request adds a secret" 1 "$r" pull_request PR_BASE_SHA="$base" PR_HEAD_SHA="$(at "$r")"
assert_summary "case 2: summary names the rule" "github-pat"
assert_summary "case 2: summary carries a fingerprint" "Fingerprint:"
# Case 9 - the credential itself never reaches the log or the summary.
assert_summary "case 9: summary redacts the credential" "$LEAK_ONE" --absent
if printf '%s' "$LAST_OUT" | grep -q -- "$LEAK_ONE"; then
    printf 'FAIL %-56s stdout leaked the credential\n' "case 9: stdout redacts the credential"; fail=$((fail + 1))
else
    printf 'ok   %-56s\n' "case 9: stdout redacts the credential"; pass=$((pass + 1))
fi

# Case 3 - deleting it in a follow-up commit is NOT remediation: it stays in the
# commits the pull request would merge, so the check must keep failing.
r="$(new_repo pr-leak-deleted)"
echo "hello" > "$r/app.js"; commit "$r" "base"
base="$(at "$r")"
printf 'const token = "%s"\n' "$LEAK_ONE" > "$r/app.js"; commit "$r" "oops"
echo "const token = process.env.TOKEN" > "$r/app.js"; commit "$r" "remove the secret"
expect "case 3: secret deleted in a follow-up commit still fails" 1 "$r" pull_request PR_BASE_SHA="$base" PR_HEAD_SHA="$(at "$r")"

# Case 3 remediation - rewriting the branch so the commit never existed clears it.
r="$(new_repo pr-leak-rewritten)"
echo "hello" > "$r/app.js"; commit "$r" "base"
base="$(at "$r")"
echo "const token = process.env.TOKEN" > "$r/app.js"; commit "$r" "feature, rewritten clean"
expect "case 3: branch rewritten without the secret passes" 0 "$r" pull_request PR_BASE_SHA="$base" PR_HEAD_SHA="$(at "$r")"

# Case 4 - controlled false positive via .gitleaksignore fingerprint.
r="$(new_repo pr-ignored)"
echo "hello" > "$r/app.js"; commit "$r" "base"
base="$(at "$r")"
printf 'const token = "%s"\n' "$LEAK_TWO" > "$r/fixture.js"; commit "$r" "add fixture"
sha="$(at "$r")"
printf '%s:fixture.js:github-pat:1\n' "$sha" > "$r/.gitleaksignore"
expect "case 4: .gitleaksignore fingerprint allowlists it" 0 "$r" pull_request PR_BASE_SHA="$base" PR_HEAD_SHA="$sha"

# Case 4 variant - inline gitleaks:allow, which survives a rebase.
r="$(new_repo pr-inline-allow)"
echo "hello" > "$r/app.js"; commit "$r" "base"
base="$(at "$r")"
printf 'const token = "%s" // gitleaks:allow\n' "$LEAK_TWO" > "$r/fixture.js"; commit "$r" "add annotated fixture"
expect "case 4: inline gitleaks:allow comment allowlists it" 0 "$r" pull_request PR_BASE_SHA="$base" PR_HEAD_SHA="$(at "$r")"

# The base branch moves while a pull request is open. Scoping from merge-base means
# a secret committed to the base branch meanwhile is not blamed on this PR.
r="$(new_repo pr-base-moved)"
echo "hello" > "$r/app.js"; commit "$r" "base"
git -C "$r" checkout -q -b feature
echo "clean feature" > "$r/feature.js"; commit "$r" "feature work"
head="$(at "$r")"
git -C "$r" checkout -q main
printf 'const token = "%s"\n' "$LEAK_ONE" > "$r/other.js"; commit "$r" "someone else leaks on main"
expect "merge-base scoping ignores a leak added to the base branch" 0 "$r" pull_request PR_BASE_SHA="$(at "$r")" PR_HEAD_SHA="$head"

echo
echo "=== push scenarios ==="

# Case 5 - push to a default branch, clean range.
r="$(new_repo push-clean)"
echo "hello" > "$r/app.js"; commit "$r" "base"
before="$(at "$r")"
echo "more" > "$r/app.js"; commit "$r" "merge pull request"
expect "case 5: clean push to a default branch" 0 "$r" push PUSH_BEFORE="$before" GITHUB_SHA="$(at "$r")"

# Case 5 - push to a default branch that carries a secret.
r="$(new_repo push-leak)"
echo "hello" > "$r/app.js"; commit "$r" "base"
before="$(at "$r")"
printf 'const token = "%s"\n' "$LEAK_ONE" > "$r/app.js"; commit "$r" "direct push"
expect "case 5: push adds a secret" 1 "$r" push PUSH_BEFORE="$before" GITHUB_SHA="$(at "$r")"

# The point of range scanning: a legacy secret already in history, outside the pushed
# range, must not fail an unrelated push. Full-history scanning is the baseline
# script's job, not a blocking check's.
r="$(new_repo push-legacy)"
printf 'const legacy = "%s"\n' "$LEAK_ONE" > "$r/old.js"; commit "$r" "legacy leak, long merged"
before="$(at "$r")"
echo "unrelated change" > "$r/new.js"; commit "$r" "unrelated work"
expect "legacy secret outside the pushed range does not block" 0 "$r" push PUSH_BEFORE="$before" GITHUB_SHA="$(at "$r")"

# Branch created by this push: no previous tip exists, so scan the tip commit only.
r="$(new_repo push-new-branch)"
printf 'const legacy = "%s"\n' "$LEAK_ONE" > "$r/old.js"; commit "$r" "legacy leak"
printf 'const token = "%s"\n' "$LEAK_TWO" > "$r/new.js"; commit "$r" "tip commit leaks too"
expect "new branch (zero sha before) scans the tip commit" 1 "$r" push \
    PUSH_BEFORE="0000000000000000000000000000000000000000" GITHUB_SHA="$(at "$r")"

r="$(new_repo push-new-branch-clean)"
printf 'const legacy = "%s"\n' "$LEAK_ONE" > "$r/old.js"; commit "$r" "legacy leak"
echo "clean tip" > "$r/new.js"; commit "$r" "clean tip commit"
expect "new branch tip-only scan ignores older history" 0 "$r" push \
    PUSH_BEFORE="0000000000000000000000000000000000000000" GITHUB_SHA="$(at "$r")"

# History rewritten: the previous tip is gone from the clone. Fall back to the tip
# commit rather than silently scanning nothing.
r="$(new_repo push-unreachable-before)"
echo "hello" > "$r/app.js"; commit "$r" "base"
printf 'const token = "%s"\n' "$LEAK_ONE" > "$r/app.js"; commit "$r" "force-pushed tip"
expect "unreachable previous tip falls back to the tip commit" 1 "$r" push \
    PUSH_BEFORE="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" GITHUB_SHA="$(at "$r")"

# Re-run of a workflow on an unchanged ref: an empty range is legitimate here.
r="$(new_repo push-empty-range)"
echo "hello" > "$r/app.js"; commit "$r" "base"
expect "empty push range passes without scanning" 0 "$r" push PUSH_BEFORE="$(at "$r")" GITHUB_SHA="$(at "$r")"
assert_summary "empty push range reports 0 commits" 'Commits scanned: `0`'

echo
echo "=== fail-closed scenarios ==="

# THE TRAP this guard exists for: gitleaks exits 0 when git resolves nothing, so an
# unfetched base SHA would otherwise report a clean scan of zero commits.
r="$(new_repo pr-unfetched-base)"
echo "hello" > "$r/app.js"; commit "$r" "base"
printf 'const token = "%s"\n' "$LEAK_ONE" > "$r/app.js"; commit "$r" "oops"
expect "unfetched base SHA fails closed, never reports clean" 2 "$r" pull_request \
    PR_BASE_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" PR_HEAD_SHA="$(at "$r")"

r="$(new_repo pr-no-shas)"
echo "hello" > "$r/app.js"; commit "$r" "base"
expect "pull request without base/head SHAs fails closed" 2 "$r" pull_request

r="$(new_repo evt-unsupported)"
echo "hello" > "$r/app.js"; commit "$r" "base"
expect "unsupported event fails closed" 2 "$r" workflow_dispatch

r="$(new_repo cfg-missing)"
echo "hello" > "$r/app.js"; commit "$r" "base"
SCAN_CONFIG="$WORK/does-not-exist.toml" \
    expect "missing central config fails closed, no silent default rules" 2 "$r" push \
    PUSH_BEFORE="$(at "$r")" GITHUB_SHA="$(at "$r")"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
