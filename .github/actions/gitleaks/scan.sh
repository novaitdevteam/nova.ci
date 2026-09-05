#!/usr/bin/env bash
#
# Gitleaks secret scan over the commits a pull request or a push ADDS.
#
# Scoping to the added commits, rather than full history, is what makes the check
# safe to make mandatory: a legacy finding already in the default branch never
# blocks an unrelated pull request. See docs/secret-detection.md.
#
# The whole contract is environment variables, so scripts/test-secret-scan.sh can
# drive every branch offline against real git fixtures:
#
#   GITLEAKS_BIN         path to the gitleaks binary            (default: gitleaks)
#   GITLEAKS_CONFIG      path to the central gitleaks.toml      (required)
#   GITLEAKS_VERSION     version string, for the summary header (optional)
#   GITHUB_EVENT_NAME    pull_request | push
#   GITHUB_SHA           tip commit of the event
#   GITHUB_REPOSITORY    owner/name, for the summary
#   PR_BASE_SHA          github.event.pull_request.base.sha
#   PR_HEAD_SHA          github.event.pull_request.head.sha
#   PR_NUMBER            github.event.pull_request.number       (cosmetic)
#   PUSH_BEFORE          github.event.before
#   GITHUB_STEP_SUMMARY  summary file to append to              (optional)
#   GITHUB_OUTPUT        step output file                       (optional)
#
# Optional, only used to compose the notifier message:
#   NOTIFY_ACTOR / NOTIFY_PR_TITLE / NOTIFY_RUN_URL / GITHUB_REF_NAME
#   PR_BASE_REF          github.event.pull_request.base.ref     — is this a merge
#   PR_HEAD_REF          github.event.pull_request.head.ref       between trunk branches?
#   DEFAULT_BRANCH       github.event.repository.default_branch — same trunk definition
#                        the push gate in ci-build-trigger-switcher.yaml uses
#
# Emits, before exiting, so a failed run can still be reported:
#   outcome   clean | leaks | error
#   findings  number of findings
#   message   ready-to-send notifier text (never contains a credential)
#
# Exit status: 0 clean, 1 secrets found, 2 the scan could not be trusted.
#
set -uo pipefail

GITLEAKS_BIN="${GITLEAKS_BIN:-gitleaks}"
GITLEAKS_CONFIG="${GITLEAKS_CONFIG:?GITLEAKS_CONFIG is required}"
LOG_FILE="${GITLEAKS_LOG_FILE:-gitleaks.log}"

# Distinct values of a Gitleaks verbose field ("Author", "Commit", "File", ...), one per
# line, in first-seen order across every finding in the log. `gitleaks git -v` prints
# these per finding, not per event — GITHUB_SHA is only the pull request's head or the
# push tip, almost never the commit that actually introduced the secret, so read the
# log instead of guessing from the event.
field_values() { # field_values <field-name> <log-file>
  awk -v f="^${1}:" '$0 ~ f { sub(f, ""); sub(/^[ \t]+/, ""); if (!seen[$0]++) print }' "$2"
}

# Name the one value when every finding agrees; otherwise say how many rather than
# picking one arbitrarily — attributing several findings to whichever one happened to
# print first is exactly the "By: avoylenko" bug this replaces.
#
# A plain while-read loop, not `mapfile`: this script targets whatever `bash` a
# contributor's machine resolves first, and macOS still ships bash 3.2 by default,
# which has no `mapfile` builtin (added in 4.0) — the same reason nothing else in
# this repository uses it.
summarize() { # summarize <noun> <cap> <newline-separated values>
  local noun="$1" cap="$2" values="$3" total=0 first="" shown="" line
  [ -n "$values" ] || { printf '?'; return; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    total=$((total + 1))
    [ "$total" -eq 1 ] && first="$line"
    [ "$total" -le "$cap" ] && shown="${shown:+$shown, }$line"
  done <<EOF
$values
EOF
  if [ "$total" -eq 1 ]; then
    printf '%s' "$first"
    return
  fi
  [ "$total" -gt "$cap" ] && shown="${shown}, +$((total - cap)) more"
  printf '%d %ss: %s' "$total" "$noun" "$shown"
}

# The same trunk definition the push gate in ci-build-trigger-switcher.yaml uses —
# main/master/development plus whatever the repository itself treats as its default
# branch. Reused here rather than reinvented so the two never drift apart.
is_trunk() { # is_trunk <ref-name>
  case "$1" in
    "") return 1 ;;
    main | master | development) return 0 ;;
  esac
  [ -n "${DEFAULT_BRANCH:-}" ] && [ "$1" = "$DEFAULT_BRANCH" ]
}

# Composed here rather than in the workflow so the harness covers it: the message is
# the whole point of the notifier, and a chat alert that is subtly wrong is worse than
# none. It distinguishes a leak ("someone committed a credential, rotate it") from a
# scan failure ("the gate is broken, this change is unscanned") — opposite reactions,
# and an alert that cannot tell them apart is one people learn to ignore.
#
# It carries no credential and not even the rule IDs: the redacted detail is in the job
# summary, behind repository access, and a chat group is a wider audience than that. File
# paths are not a rule ID — they are usually enough on their own to recognise a fixture
# or documentation directory, which is the whole reason this notifier exists: so nobody
# has to open the run to learn that much.
compose() { # compose <outcome> <findings>
  local outcome="$1" count="${2:-0}" head advice where
  local branch="${GITHUB_REF_NAME:-?}" pr="${PR_NUMBER:-?}"

  if [ "$outcome" = leaks ]; then
    # Per-finding attribution, not the PR author or the event's tip SHA: the person who
    # can act on a finding is whoever committed it, which may be neither.
    local who what files_line
    who="$(summarize author 5 "$(field_values Author "$LOG_FILE")")"
    what="$(summarize commit 5 "$(field_values Commit "$LOG_FILE" | cut -c1-8 | awk '!seen[$0]++')")"
    files_line="$(summarize file 10 "$(field_values File "$LOG_FILE")")"

    if [ "${GITHUB_EVENT_NAME:-}" = pull_request ]; then
      head="⚠️ SECRET DETECTED in a pull request — ${GITHUB_REPOSITORY:-?}"
      if is_trunk "${PR_BASE_REF:-}" && is_trunk "${PR_HEAD_REF:-}"; then
        # A release-style merge between two long-lived branches: the commits were
        # already reviewed and merged on ${PR_HEAD_REF} once, so rewriting either
        # branch is not on the table — nobody rebases or force-pushes a trunk branch
        # to clear a check.
        advice="Do not merge. This pull request merges ${PR_HEAD_REF:-?} into ${PR_BASE_REF:-?} —
both long-lived branches, so rewriting either one is not an option. Fix it forward
instead: if the credential is real, rotate it at the provider now — it has been
reachable on ${PR_HEAD_REF:-?} since the commit(s) below. Then push a NEW commit to
${PR_HEAD_REF:-?} that removes it, or, if this is a false positive, allowlists the
fingerprint (.gitleaksignore or an inline gitleaks:allow — see
docs/secret-detection.md). Pushing to ${PR_HEAD_REF:-?} updates this pull request's
commit range automatically."
      else
        advice="Do not merge. The secret is in the pull request's commits, so merging buries it in
history. Rotate the credential, then rewrite the branch (git rebase -i or
git commit --amend, then force-push). Deleting the line in a NEW commit will not
clear this check."
      fi
      where="Pull request: #${pr}${NOTIFY_PR_TITLE:+ — $NOTIFY_PR_TITLE}"
    else
      head="🚨 SECRET DETECTED on a protected branch — ${GITHUB_REPOSITORY:-?}"
      advice="The credential is in ${branch} history now. Rotate or revoke it at the provider
immediately. Deleting the line is not remediation — the secret stays in history."
      where="Branch: ${branch}"
    fi
    printf '%s\n\n%s\n\n%s\nAuthor: %s\nCommit: %s\nFindings: %s (values redacted)\nFiles: %s\n\n%s\n%s\n' \
      "$head" "$advice" "$where" "$who" "$what" "$count" "$files_line" \
      "Details (file, line, rule, fingerprint) - no plaintext values:" "${NOTIFY_RUN_URL:-?}"
  else
    head="🔧 secret-scan could not run — ${GITHUB_REPOSITORY:-?}"
    advice="The scan failed before it could report a finding, so this change is UNSCANNED.
This is not a leak alert — it is a broken gate. Open the run and fix it."
    if [ "${GITHUB_EVENT_NAME:-}" = pull_request ]; then
      where="Pull request: #${pr}"
    else
      where="Branch: ${branch}"
    fi
    printf '%s\n\n%s\n\n%s\nBy: %s\nCommit: %s\n\n%s\n' \
      "$head" "$advice" "$where" "${NOTIFY_ACTOR:-?}" "${GITHUB_SHA:0:8}" "${NOTIFY_RUN_URL:-?}"
  fi
}

# Written before every exit, so a failing job can still be reported.
emit() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  {
    printf 'outcome=%s\nfindings=%s\n' "$1" "${2:-0}"
    if [ "$1" != clean ]; then
      # Heredoc-delimited: the message is multi-line and may contain a PR title with
      # quotes. The delimiter is one no PR title will contain.
      echo "message<<SECRET_SCAN_MSG_EOF"
      compose "$1" "${2:-0}"
      echo "SECRET_SCAN_MSG_EOF"
    fi
  } >> "$GITHUB_OUTPUT"
}

die() { emit error 0; echo "::error::secret-scan: $*"; exit 2; }

# A missing or unreadable config is not a reason to fall back to the built-in rule
# set: that would silently drop the central allowlist and NovaTalks rules.
[ -r "$GITLEAKS_CONFIG" ] || die "config not readable: $GITLEAKS_CONFIG"
command -v "$GITLEAKS_BIN" >/dev/null 2>&1 || [ -x "$GITLEAKS_BIN" ] \
  || die "gitleaks binary not found: $GITLEAKS_BIN"

# Resolve a commit-ish to a SHA, or fail. Guards the trap below.
resolve() { git rev-parse --verify --quiet "${1}^{commit}" 2>/dev/null; }

case "${GITHUB_EVENT_NAME:-}" in
  pull_request)
    base_in="${PR_BASE_SHA:-}"
    head_in="${PR_HEAD_SHA:-}"
    [ -n "$base_in" ] && [ -n "$head_in" ] \
      || die "pull request event without base/head SHA — cannot scope the scan"

    base_sha="$(resolve "$base_in")" \
      || die "base commit $base_in is not in this clone (need fetch-depth: 0)"
    head_sha="$(resolve "$head_in")" \
      || die "head commit $head_in is not in this clone (need fetch-depth: 0)"

    # merge-base, not base.sha: the base branch moves while a pull request is open,
    # and base.sha..head would then span commits the pull request never touched.
    base_sha="$(git merge-base "$base_sha" "$head_sha")" \
      || die "no merge base between $base_in and $head_in"

    range="${base_sha}..${head_sha}"
    scope="pull request #${PR_NUMBER:-?} — commits added over \`${base_sha:0:8}\`"
    ;;
  push)
    head_sha="$(resolve "${GITHUB_SHA:-HEAD}")" \
      || die "push tip ${GITHUB_SHA:-HEAD} is not in this clone"

    before="${PUSH_BEFORE:-}"
    base_sha=""
    case "$before" in
      "" | 0000000000000000000000000000000000000000) ;;
      *) base_sha="$(resolve "$before")" || base_sha="" ;;
    esac

    if [ -n "$base_sha" ]; then
      range="${base_sha}..${head_sha}"
      scope="push — commits added over \`${base_sha:0:8}\`"
    else
      # Branch just created, force-pushed over, or history rewritten: there is no
      # honest "added" range, so scan the tip commit rather than all of history —
      # full history is the baseline scan's job, not a blocking check's.
      range="${head_sha} --max-count=1"
      scope="push — no reachable previous tip, scanning tip commit \`${head_sha:0:8}\` only"
    fi
    ;;
  *)
    die "unsupported event '${GITHUB_EVENT_NAME:-<unset>}' — wire pull_request or push only"
    ;;
esac

# THE TRAP: `gitleaks git --log-opts` hands the range to `git log` and exits 0 when
# git resolves nothing, so a typo or an unfetched SHA reports a clean scan of zero
# commits. Count the commits ourselves first and fail closed if git disagrees.
# shellcheck disable=SC2086
commits="$(git rev-list --count --no-merges $range 2>/dev/null)" \
  || die "git could not resolve the scan range '$range'"

log_opts="--no-merges $range"

echo "secret-scan: $scope"
echo "secret-scan: range '$range' -> $commits commit(s)"

if [ "$commits" -eq 0 ]; then
  # Legitimate for a re-run or an empty push; impossible for a real pull request,
  # so say so out loud instead of reporting a silent pass.
  [ "${GITHUB_EVENT_NAME:-}" = "push" ] \
    || echo "::warning::secret-scan: pull request resolved to 0 commits — nothing to scan"
  status=0
  : > "$LOG_FILE"
else
  # --redact blanks Secret and Match in stdout AND in any report file (verified on
  # 8.30.1). -v prints file, line, rule, commit and fingerprint — everything
  # remediation needs, and nothing more.
  # shellcheck disable=SC2086
  "$GITLEAKS_BIN" git \
    --no-banner --no-color --redact -v \
    --config "$GITLEAKS_CONFIG" \
    --log-opts "$log_opts" \
    . >"$LOG_FILE" 2>&1
  status=$?
fi

findings="$(grep -c '^Fingerprint:' "$LOG_FILE" 2>/dev/null || true)"
findings="${findings:-0}"

# gitleaks returns 1 both for "leaks found" and for its own startup errors (a bad
# config, for one). No fingerprint in the log means it never got to scanning, and
# an unexplained failure must not be reported as a clean run.
if [ "$status" -ne 0 ] && [ "$findings" -eq 0 ]; then
  cat "$LOG_FILE"
  die "gitleaks exited $status without reporting a finding — treating as scan failure"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  if [ "$findings" -gt 0 ]; then
    alert="CAUTION"
    headline="🚨 ${findings} secret(s) detected in the commits this change adds — do not merge, rotate first."
  else
    alert="NOTE"
    headline="✅ No secrets detected in the ${commits} commit(s) this change adds."
  fi
  {
    echo "## 🔑 Secret scan (Gitleaks ${GITLEAKS_VERSION:-pinned})"
    echo ""
    echo "> [!${alert}]"
    echo "> ${headline}"
    echo ""
    echo "- Repository: \`${GITHUB_REPOSITORY:-?}\`"
    echo "- Scope: ${scope}"
    echo "- Commits scanned: \`${commits}\`"
    echo "- Config: [\`security/gitleaks/gitleaks.toml\`](https://github.com/novaitdevteam/nova.ci/blob/main/security/gitleaks/gitleaks.toml)"
    if [ "$findings" -gt 0 ]; then
      echo ""
      echo "Values below are redacted — the report carries the fingerprint, not the credential."
      echo ""
      echo '```'
      cat "$LOG_FILE"
      echo '```'
      echo ""
      echo "**Fix it:** rotate the credential first, then rewrite the branch so the secret"
      echo "leaves git history (\`git rebase -i\` / \`git commit --amend\` + force-push) — a"
      echo "follow-up delete commit leaves it in history and will not clear this check."
      echo "False positive? See [docs/secret-detection.md](https://github.com/novaitdevteam/nova.ci/blob/main/docs/secret-detection.md)."
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$findings" -gt 0 ]; then
  emit leaks "$findings"
  cat "$LOG_FILE"
  echo "::error::secret-scan: ${findings} secret(s) detected — see the job summary for file, line, rule and fingerprint."
  exit 1
fi

emit clean 0
echo "secret-scan: clean"
exit 0
