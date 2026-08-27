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

# generic-api-key needs a keyword next to a high-entropy value, so these halves live on
# their own lines, away from the word "apiKey". Spelling the value out in full on one line
# turns nova.ci's own secret-scan red - the self-scan assertion at the end of this file is
# what notices.
H1='8f4c2e9a1b7d'
H2='3f6e5c0a9b8d7e6f5a4c'
FAKE_ENTROPY="${H1}${H2}"

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
    local summary="$WORK/summary.md" outfile="$WORK/output.txt" out
    : > "$summary"
    : > "$outfile"
    set +e
    out="$(cd "$repo" && env \
        GITLEAKS_BIN="$GITLEAKS_BIN" \
        GITLEAKS_CONFIG="${SCAN_CONFIG:-$CONFIG}" \
        GITLEAKS_VERSION="$VERSION" \
        GITLEAKS_LOG_FILE="$WORK/gitleaks.log" \
        GITHUB_STEP_SUMMARY="$summary" \
        GITHUB_OUTPUT="$outfile" \
        GITHUB_REF_NAME="${SCAN_REF_NAME:-development}" \
        NOTIFY_ACTOR="someone" \
        NOTIFY_RUN_URL="https://github.com/novaitdevteam/fixture/actions/runs/42" \
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
    LAST_OUTPUT="$outfile"
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

assert_output() { # assert_output <name> <grep-pattern> [--absent]
    local name="$1" pat="$2" mode="${3:-present}"
    if grep -q -- "$pat" "$LAST_OUTPUT"; then
        if [ "$mode" = "--absent" ]; then
            printf 'FAIL %-56s output must NOT contain %s\n' "$name" "$pat"; fail=$((fail + 1)); return
        fi
    elif [ "$mode" != "--absent" ]; then
        printf 'FAIL %-56s output missing %s\n' "$name" "$pat"
        sed 's/^/       | /' "$LAST_OUTPUT"; fail=$((fail + 1)); return
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

# Case 4 variant - a fingerprint with the commit stripped. Pins to file:rule:line only,
# so it survives a rebase (the commit-qualified form does not). The trade is that it
# breaks when the line number shifts, so it is the right form for a branch still in
# flight and the wrong one for a permanent exception.
r="$(new_repo pr-ignored-commitless)"
echo "hello" > "$r/app.js"; commit "$r" "base"
base="$(at "$r")"
printf 'const token = "%s"\n' "$LEAK_TWO" > "$r/fixture.js"; commit "$r" "add fixture"
printf 'fixture.js:github-pat:1\n' > "$r/.gitleaksignore"
expect "case 4: commitless fingerprint also allowlists it" 0 "$r" pull_request PR_BASE_SHA="$base" PR_HEAD_SHA="$(at "$r")"

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
echo "=== central allowlist scenarios ==="
# The config carries exactly one path-scoped allowlist, and it is scoped to the
# heuristic generic-api-key rule. These four assertions ARE the safety argument: if a
# future edit drops targetRules or widens the paths, a real credential in a test file
# stops failing and this goes red.

r="$(new_repo allow-fixture-generic)"
echo "hello" > "$r/app.js"; commit "$r" "base"
base="$(at "$r")"
mkdir -p "$r/src"
# High-entropy invented value, the shape a test fixture has.
printf 'const apiKey = "%s"\n' "$FAKE_ENTROPY" > "$r/src/thing.spec.ts"
commit "$r" "add a spec with an invented token"
expect "allowlist: invented token in a .spec.ts passes" 0 "$r" pull_request PR_BASE_SHA="$base" PR_HEAD_SHA="$(at "$r")"

# THE safety property: relaxing the heuristic rule must not relax the provider rules.
r="$(new_repo allow-fixture-real-provider)"
echo "hello" > "$r/app.js"; commit "$r" "base"
base="$(at "$r")"
mkdir -p "$r/src"
printf 'const gh = "%s"\n' "$LEAK_ONE" > "$r/src/thing.spec.ts"
commit "$r" "add a spec with a real-format github token"
expect "allowlist: provider-rule hit in a .spec.ts STILL fails" 1 "$r" pull_request PR_BASE_SHA="$base" PR_HEAD_SHA="$(at "$r")"
assert_summary "allowlist: it fails on the provider rule, not the heuristic" "github-pat"

# The allowlist must not leak out of test paths into product code.
r="$(new_repo allow-product-code)"
echo "hello" > "$r/app.js"; commit "$r" "base"
base="$(at "$r")"
mkdir -p "$r/src"
printf 'const apiKey = "%s"\n' "$FAKE_ENTROPY" > "$r/src/thing.ts"
commit "$r" "same invented token, but in product code"
expect "allowlist: same token in product code still fails" 1 "$r" pull_request PR_BASE_SHA="$base" PR_HEAD_SHA="$(at "$r")"

echo
echo "=== notifier message scenarios ==="
# The chat alert is the compensating control for not being able to block a merge, so a
# subtly wrong message is worse than none. It must also never carry the credential.

r="$(new_repo notify-pr-leak)"
echo "hello" > "$r/app.js"; commit "$r" "base"
base="$(at "$r")"
printf 'const token = "%s"\n' "$LEAK_ONE" > "$r/app.js"; commit "$r" "oops"
expect "notify: PR leak still exits 1" 1 "$r" pull_request PR_BASE_SHA="$base" PR_HEAD_SHA="$(at "$r")"
assert_output "notify: PR leak sets outcome=leaks" "outcome=leaks"
assert_output "notify: PR leak counts the finding" "findings=1"
assert_output "notify: PR message says do not merge" "Do not merge"
assert_output "notify: PR message names the pull request" "Pull request: #1"
assert_output "notify: PR message links the run" "actions/runs/42"
assert_output "notify: PR message never carries the credential" "$LEAK_ONE" --absent
assert_output "notify: PR message leaks no rule ID to chat" "github-pat" --absent

r="$(new_repo notify-push-leak)"
echo "hello" > "$r/app.js"; commit "$r" "base"
before="$(at "$r")"
printf 'const token = "%s"\n' "$LEAK_ONE" > "$r/app.js"; commit "$r" "direct push"
expect "notify: protected-branch leak still exits 1" 1 "$r" push PUSH_BEFORE="$before" GITHUB_SHA="$(at "$r")"
assert_output "notify: push message says protected branch" "on a protected branch"
assert_output "notify: push message names the branch" "Branch: development"
assert_output "notify: push message tells you to rotate" "Rotate or revoke"
assert_output "notify: push message never carries the credential" "$LEAK_ONE" --absent

# A broken gate and a leaked credential need opposite reactions, so they must not
# produce the same alert.
r="$(new_repo notify-error)"
echo "hello" > "$r/app.js"; commit "$r" "base"
SCAN_CONFIG="$WORK/does-not-exist.toml" \
    expect "notify: broken gate still exits 2" 2 "$r" push \
    PUSH_BEFORE="$(at "$r")" GITHUB_SHA="$(at "$r")"
assert_output "notify: broken gate sets outcome=error" "outcome=error"
assert_output "notify: broken gate message says UNSCANNED" "UNSCANNED"
assert_output "notify: broken gate is not reported as a leak" "SECRET DETECTED" --absent

r="$(new_repo notify-clean)"
echo "hello" > "$r/app.js"; commit "$r" "base"
base="$(at "$r")"
echo "clean change" > "$r/app.js"; commit "$r" "feature"
expect "notify: clean run passes" 0 "$r" pull_request PR_BASE_SHA="$base" PR_HEAD_SHA="$(at "$r")"
assert_output "notify: clean run sets outcome=clean" "outcome=clean"
assert_output "notify: clean run composes no message" "message<<" --absent

echo
echo "=== self-scan: nova.ci's own commits ==="
# Mirrors exactly what ci-self-validate.yaml runs on a pull request, so a fixture in THIS
# file that trips the scanner is caught before the push rather than by a red PR. That is
# not hypothetical: the first version of the allowlist scenarios spelled a high-entropy
# value out in full next to the word "apiKey" and turned nova.ci's own secret-scan red.
# The halves convention near the top of this file prevents it; this notices when someone
# forgets.
#
# The commit range, not the working tree: `gitleaks dir` does not honour .gitignore, so a
# tree scan would fail on any developer's untracked local .env.
base=""
for ref in origin/main main; do
    base="$(git -C "$ROOT" merge-base "$ref" HEAD 2>/dev/null)" && [ -n "$base" ] && break
    base=""
done
head_sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"

if [ -z "$base" ] || [ -z "$head_sha" ]; then
    echo "skip: cannot resolve a range against main"
elif [ "$base" = "$head_sha" ]; then
    echo "skip: no commits ahead of main"
else
    set +e
    self_out="$(cd "$ROOT" && env \
        GITLEAKS_BIN="$GITLEAKS_BIN" \
        GITLEAKS_CONFIG="$CONFIG" \
        GITLEAKS_VERSION="$VERSION" \
        GITLEAKS_LOG_FILE="$WORK/self.log" \
        GITHUB_EVENT_NAME=pull_request \
        GITHUB_REPOSITORY=novaitdevteam/nova.ci \
        GITHUB_SHA="$head_sha" \
        PR_BASE_SHA="$base" PR_HEAD_SHA="$head_sha" PR_NUMBER=0 \
        bash "$SCAN" 2>&1)"
    self_rc=$?
    set -e
    if [ "$self_rc" -eq 0 ]; then
        printf 'ok   %-56s\n' "self-scan: nova.ci's own commits are clean"
        pass=$((pass + 1))
    else
        printf '%s\n' "$self_out" | sed 's/^/       | /'
        printf 'FAIL %-56s exit=%s\n' "self-scan: nova.ci's own commits" "$self_rc"
        echo "       nova.ci trips its own scanner - ci-self-validate.yaml will go red."
        echo "       A fixture in this file? Split the value - see H1/H2 near the top."
        echo "       Already committed? A later fix does not clear it; rewrite the branch."
        fail=$((fail + 1))
    fi
fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
