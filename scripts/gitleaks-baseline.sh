#!/usr/bin/env bash
#
# One-time full-history secret scan of the product repositories (NC2-2742 §6).
#
# CI only ever scans the commits a change ADDS, so a credential already sitting in
# history never blocks a pull request — and never gets noticed either. This script is
# the other half: it reads the whole history once, so anything already leaked can be
# rotated. It is deliberately NOT a CI job; it is an audit you run, read and act on.
#
# Findings are redacted: you get repository, file, line, rule, commit and fingerprint,
# never the credential. Rotate from the provider's console, not from this output.
#
# Usage:
#   ./scripts/gitleaks-baseline.sh                 # every repository on the NC2-2742 list
#   ./scripts/gitleaks-baseline.sh novatalks.core  # just these
#
# Requires: gh (authenticated), git, and either gitleaks on PATH or network access to
# download the pinned build.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION_DIR="$ROOT/.github/actions/gitleaks"
CONFIG="$ROOT/security/gitleaks/gitleaks.toml"
ORG="${ORG:-novaitdevteam}"
OUT_DIR="${OUT_DIR:-$ROOT/.baseline}"

# The NC2-2742 list: exactly the repositories secret-scan covers in CI, so the audit
# and the gate agree on scope. Out of scope: novatalks.tests, nova.ai.marketplace,
# novatalks.charts, novatalks.grafana.connector; the genesys wizard is deprecated.
# Those get no CI coverage at all, so auditing them is a manual job - pass repository
# names as arguments to scan anything outside this list.
DEFAULT_REPOS=(
    novatalks.core
    novatalks.ui
    novatalks.ui-lite
    nova.botflow
    novatalks.dialer
    novatalks.chatwidget
    novatalks.geoip-api
    novatalks.uspacy.connector
    nova.chatsconnector.telegram-client-api
    nova.chatsconnector.whatsapp-client-api
    nova.chatsconnector.signal-client-api
    nova.ci
)

repos=("$@")
[ "${#repos[@]}" -gt 0 ] || repos=("${DEFAULT_REPOS[@]}")

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh is required (brew install gh; gh auth login)"; exit 1; }
[ -r "$CONFIG" ] || { echo "ERROR: central config missing: $CONFIG"; exit 1; }

# Same pin as CI, read from the same place, so the audit and the gate agree on rules.
VERSION="$(sed -n 's/.*GITLEAKS_VERSION: *"\([0-9.]*\)".*/\1/p' "$ACTION_DIR/action.yml" | head -1)"
if [ -n "${GITLEAKS_BIN:-}" ] && [ -x "$GITLEAKS_BIN" ]; then
    :
elif command -v gitleaks >/dev/null 2>&1; then
    GITLEAKS_BIN="$(command -v gitleaks)"
else
    echo "ERROR: gitleaks not found. Install the pinned version ${VERSION}:"
    echo "  brew install gitleaks   # or download v${VERSION} from the releases page"
    exit 1
fi

mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf 'gitleaks %s (pin %s) · config %s\n' \
    "$("$GITLEAKS_BIN" version 2>/dev/null || echo '?')" "$VERSION" "${CONFIG#"$ROOT"/}"
printf 'reports  %s\n\n' "$OUT_DIR"

total=0
declare -a summary_rows=()

for repo in "${repos[@]}"; do
    printf '=== %s ===\n' "$repo"
    if ! gh repo clone "$ORG/$repo" "$WORK/$repo" -- --quiet --no-single-branch >/dev/null 2>&1; then
        printf '  skip: cannot clone %s/%s\n\n' "$ORG" "$repo"
        summary_rows+=("$repo|clone failed|-")
        continue
    fi

    # Every branch and tag, not just the default branch: a secret on an abandoned
    # branch is just as live as one on main.
    git -C "$WORK/$repo" fetch -q --all --tags 2>/dev/null || true

    report="$OUT_DIR/${repo}.json"
    set +e
    "$GITLEAKS_BIN" git \
        --no-banner --no-color --redact \
        --config "$CONFIG" \
        --log-opts "--all" \
        --report-format json --report-path "$report" \
        "$WORK/$repo" >"$WORK/$repo.log" 2>&1
    status=$?
    set -e

    # Count without jq: it is not installed everywhere, and the field is stable.
    count="$(grep -c '"Fingerprint":' "$report" 2>/dev/null || true)"
    count="${count:-0}"

    if [ "$status" -gt 1 ] || { [ "$status" -eq 1 ] && [ "$count" -eq 0 ]; }; then
        tail -5 "$WORK/$repo.log" | sed 's/^/  /'
        printf '  ERROR: scan failed\n\n'
        summary_rows+=("$repo|scan failed|-")
        continue
    fi

    commits="$(git -C "$WORK/$repo" rev-list --count --all 2>/dev/null || echo '?')"
    printf '  %s commits, %s finding(s) -> %s\n' "$commits" "$count" "${report#"$ROOT"/}"

    if [ "$count" -gt 0 ]; then
        # Rule + file only, so the console stays skimmable and leaks nothing.
        sed -n 's/.*"RuleID": *"\([^"]*\)".*/\1/p' "$report" | sort | uniq -c | sort -rn | sed 's/^/    /'
    fi
    printf '\n'

    total=$((total + count))
    summary_rows+=("$repo|$count|$commits")
    rm -rf "${WORK:?}/${repo:?}"
done

printf '=== baseline summary ===\n'
printf '%-45s %10s %10s\n' "repository" "findings" "commits"
for row in "${summary_rows[@]}"; do
    IFS='|' read -r a b c <<< "$row"
    printf '%-45s %10s %10s\n' "$a" "$b" "$c"
done
printf '\n%s finding(s) total across %s repositor(y|ies)\n\n' "$total" "${#repos[@]}"

cat <<'NEXT'
Classify every finding before touching enforcement. For each one:

  actual secret     -> ROTATE first (provider console), then remove from source.
                       Deleting the line is not remediation: it stays in history.
  false positive    -> add the fingerprint to that repository's .gitleaksignore,
                       or an inline `gitleaks:allow` comment, with a reason.
  obsolete/revoked  -> confirm revoked at the provider, then treat as false positive.
  test fixture      -> make it obviously fake, then `gitleaks:allow` the line.

Reports under .baseline/ are redacted but still name files and commits — keep them
out of git (.gitignore covers .baseline) and out of chat.
NEXT
