#!/usr/bin/env bash
#
# Cross-check the checked-out source's lockfiles against two independent vulnerability
# databases and turn the result into a .report file, a job summary, and outputs.
#
# Trivy's own image scan (trivy-scan in the build workflow) already reads dependencies
# that ship INSIDE a built image. What it structurally cannot see: a frontend bundle with
# no manifest (novatalks.ui ships `dist/`, no node_modules, no lockfile), a devDependency
# pruned out of the image (`npm prune --omit=dev`), or any repository that builds no
# image at all and so never reaches trivy-scan. This script reads the checkout directly,
# on every pull request, before an image exists.
#
# Two engines, two databases, on purpose: `trivy fs` (aquasecurity's own feed) and
# OSV-Scanner (osv.dev, which aggregates GHSA and the npm advisory feed among others).
# Neither is a substitute for the other and neither is de-duplicated against the other —
# a genuine cross-check is the point.
#
# The property both guards below exist for, verified live against both tools while
# writing this script, not assumed: a scanner that could not run can produce exactly the
# output a clean scan produces.
#   - Trivy: a real DB-fetch failure with no cache exits non-zero and writes no JSON at
#     all (reproduced: `--skip-db-update` with an empty cache dir -> FATAL, exit 1, empty
#     stdout) — so "no output file" is real signal, not a corner nobody hits.
#   - OSV-Scanner: a real network failure reaching api.osv.dev (reproduced with
#     `docker run --network none`) still writes a perfectly well-formed JSON document —
#     the lockfile was found, the package list is populated, and the vulnerability query
#     simply came back with nothing because it never left the container. The JSON alone
#     is indistinguishable from a genuinely clean scan. Only the exit code carries the
#     signal: 0 (clean), 1 (vulnerabilities found) and 128 (no package sources found) are
#     the three documented outcomes (github.com/google/osv-scanner
#     cmd/osv-scanner/internal/cmd/run.go); anything else — 127 generic error, 129
#     ErrAPIFailed, 130 SIGINT — is a scanner error even though stdout looks fine. This is
#     the same shape as the ZAP `0|1|2` exit ladder elsewhere in this repository: the exit
#     code is load-bearing and the JSON body is not enough on its own.
#
# No synthetic canary file is needed here, unlike Semgrep's: a repository's own real
# lockfile and its own real package list ARE the proof of parsing, once the guards above
# rule out the "ran but silently learned nothing" cases. A repository with no lockfile at
# all is reported as its own outcome, `no-manifests` — never folded into `clean`.
#
set -euo pipefail

: "${OSV_IMAGE:?}" "${DEPS_SRC:?}" "${DEPS_REPORT_FILE:?}"
: "${TRIVY_JSON:?}" "${TRIVY_OUTCOME:?}"

emit() { # emit <key> <value>
    printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/null}"
}

emit_message() { # emit_message <text>
    {
        echo "message<<DEPS_EOF"
        printf '%s\n' "$1"
        echo "DEPS_EOF"
    } >> "${GITHUB_OUTPUT:-/dev/null}"
}

finish_error() { # finish_error <reason>
    local reason="$1"
    echo "::error::Dependency scan could not complete: ${reason}"
    emit outcome error
    emit findings 0
    emit_message "📚 Deps (Trivy fs + OSV): ❌ scan failed — ${reason}"
    {
        echo "## 📦 Dependency scan (Trivy fs + OSV-Scanner)"
        echo ""
        echo "> [!CAUTION]"
        echo "> Scan did not complete: ${reason}. This is a broken gate, not a clean result."
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    exit 2
}

# ---------------------------------------------------------------------------
# Trivy: read the JSON the caller's own `aquasecurity/trivy-action` step wrote (called
# directly in the workflow, the same place every other Trivy job in this repository calls
# it — there is no validate.sh wrapper guard for Trivy the way there is for Gitleaks,
# Semgrep and ZAP). TRIVY_OUTCOME is that step's own `outcome`, passed in because a
# composite action step that failed would otherwise stop this action before it could ever
# write a report — the same reason Semgrep's scan.sh runs its own docker invocation under
# `set +e` rather than letting a failure abort the script.
# ---------------------------------------------------------------------------
trivy_state="error"
trivy_reason=""
trivy_findings=0
trivy_packages=0

if [ "$TRIVY_OUTCOME" != "success" ]; then
    trivy_reason="the Trivy step's own outcome was '${TRIVY_OUTCOME}', not success"
elif [ ! -s "$TRIVY_JSON" ]; then
    trivy_reason="Trivy produced no output file at ${TRIVY_JSON}"
elif ! jq -e . "$TRIVY_JSON" >/dev/null 2>&1; then
    trivy_reason="Trivy output is not valid JSON"
else
    trivy_packages=$(jq '[.Results[]?.Packages[]?] | length' "$TRIVY_JSON")
    if [ "$trivy_packages" -gt 0 ]; then
        trivy_state="parsed"
        trivy_findings=$(jq '[.Results[]?.Vulnerabilities[]?] | length' "$TRIVY_JSON")
    else
        trivy_state="no-manifest"
    fi
fi

# ---------------------------------------------------------------------------
# OSV-Scanner: invoked here directly, via the pinned digest, the same shape Semgrep's
# scan.sh uses for its own docker run. `--recursive` matters for parity with Trivy, which
# walks subdirectories by default — without it a lockfile one directory down (a monorepo
# frontend/backend split) reports `no package sources found` here while Trivy still finds
# it, a false no-manifest reproduced while writing this script. `--all-packages` prints
# every scanned package, not only vulnerable ones — it is what lets a clean scan still
# prove a lockfile was read.
# ---------------------------------------------------------------------------
osv_json="${RUNNER_TEMP:-/tmp}/osv-scanner.json"
osv_err="${RUNNER_TEMP:-/tmp}/osv-scanner.stderr"

set +e
docker run --rm \
    -v "${DEPS_SRC}:/src:ro" \
    -w /src \
    "$OSV_IMAGE" \
    scan --format json --all-packages --recursive /src \
    > "$osv_json" 2> "$osv_err"
osv_rc=$?
set -e

osv_state="error"
osv_reason=""
osv_findings=0
osv_packages=0

case "$osv_rc" in
    0|1)
        if jq -e . "$osv_json" >/dev/null 2>&1; then
            osv_packages=$(jq '[.results[]?.packages[]?] | length' "$osv_json")
            if [ "$osv_packages" -gt 0 ]; then
                osv_state="parsed"
                osv_findings=$(jq '[.results[]?.packages[]?.vulnerabilities[]?] | length' "$osv_json")
            else
                # Exit 0/1 with zero packages should not happen (OSV-Scanner exits 128 in
                # that case instead) — but if the JSON shape ever changes under the pin,
                # fail closed to "no proof of parsing" rather than assume clean.
                osv_state="no-manifest"
            fi
        else
            osv_reason="OSV-Scanner exited ${osv_rc} but its output is not valid JSON"
        fi
        ;;
    128)
        # ErrNoPackagesFound (cmd/osv-scanner/internal/cmd/run.go) — a legitimate state,
        # not a scanner error. No stdout is written in this case at all.
        osv_state="no-manifest"
        ;;
    *)
        # Every other exit code is a scanner error, even when stdout parses as valid
        # JSON: 127 (generic error) and 129 (ErrAPIFailed) can both leave a well-formed
        # document behind with a populated package list and zero vulnerabilities, because
        # the failure happened after the lockfile was read and before the OSV query
        # returned — reproduced with `docker run --network none` while writing this
        # script. Only the exit code tells the two apart.
        osv_reason="OSV-Scanner exited ${osv_rc} (see log below for the reason)"
        ;;
esac

if [ "$osv_state" = "error" ]; then
    echo "OSV-Scanner stderr:"
    sed 's/^/  /' "$osv_err" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Combine. Either tool reporting error dominates: a tool that could not prove what it did
# is not offset by the other tool's zero, findings or no-manifest — see the header comment.
# ---------------------------------------------------------------------------
if [ "$trivy_state" = "error" ] || [ "$osv_state" = "error" ]; then
    reasons=()
    [ "$trivy_state" = "error" ] && reasons+=("Trivy: ${trivy_reason}")
    [ "$osv_state" = "error" ] && reasons+=("OSV-Scanner: ${osv_reason}")
    IFS='; '
    finish_error "${reasons[*]}"
fi

findings=$(( trivy_findings + osv_findings ))

if [ "$trivy_state" = "no-manifest" ] && [ "$osv_state" = "no-manifest" ]; then
    outcome="no-manifests"
elif [ "$findings" -gt 0 ]; then
    outcome="findings"
else
    outcome="clean"
fi

# ---------------------------------------------------------------------------
# Report: package, installed version, fixed version, severity, advisory ID — per tool,
# never merged into one row, since the whole point is that the two databases are
# independent and may disagree.
# ---------------------------------------------------------------------------
trivy_rows() {
    jq -r '.Results[]? | .Vulnerabilities[]? |
        "\(.Severity)\t\(.PkgName)\t\(.InstalledVersion)\t\(.FixedVersion // "unknown")\t\(.VulnerabilityID)"' \
        "$TRIVY_JSON" 2>/dev/null || true
}

osv_rows() {
    jq -r '
        .results[]?.packages[]? as $p |
        ($p.vulnerabilities // [])[] as $v |
        ([$v.affected[]?
            | select(.package.name == $p.package.name and .package.ecosystem == $p.package.ecosystem)
            | .ranges[]?.events[]? | .fixed]
          | map(select(. != null)) | first // "unknown") as $fixed |
        "\($v.database_specific.severity // "UNKNOWN")\t\($p.package.name)\t\($p.package.version)\t\($fixed)\t\($v.id)"
    ' "$osv_json" 2>/dev/null || true
}

{
    echo "=============================="
    echo " Dependency scan: Trivy fs + OSV-Scanner"
    echo " Reads: declared dependencies in the checkout's own lockfiles."
    echo " Does NOT read: vendored code with no manifest entry, or code we wrote."
    echo "=============================="
    echo ""
    echo "=== Trivy (fs, vuln): ${trivy_state} — ${trivy_findings} finding(s), ${trivy_packages} package(s) scanned ==="
    echo ""
    trivy_rows
    echo ""
    echo "=== OSV-Scanner: ${osv_state} — ${osv_findings} finding(s), ${osv_packages} package(s) scanned ==="
    echo ""
    osv_rows
} > "$DEPS_REPORT_FILE"

alert=NOTE
case "$outcome" in
    findings)
        alert=WARNING
        headline="⚠️ ${findings} dependency finding(s) — Trivy: ${trivy_findings}, OSV-Scanner: ${osv_findings}. Review the report."
        echo "::warning::Dependency scan found ${findings} finding(s) (Trivy: ${trivy_findings}, OSV-Scanner: ${osv_findings}). See ${DEPS_REPORT_FILE}."
        ;;
    no-manifests)
        alert=WARNING
        headline="⚠️ No lockfile found by either tool. This is a legitimate state, not a clean scan — nothing was checked."
        ;;
    clean)
        headline="✅ No findings. At least one lockfile was found and parsed."
        ;;
esac

{
    echo "## 📦 Dependency scan (Trivy fs + OSV-Scanner)"
    echo ""
    echo "> [!${alert}]"
    echo "> ${headline}"
    echo ""
    echo "- Reads declared dependencies in the checkout's own lockfiles — not vendored"
    echo "  code with no manifest entry, and not code we wrote (that is Semgrep's job)."
    echo "- Trivy: \`${trivy_state}\` — ${trivy_findings} finding(s), ${trivy_packages} package(s) scanned"
    echo "- OSV-Scanner: \`${osv_state}\` — ${osv_findings} finding(s), ${osv_packages} package(s) scanned"
    echo "- Report: ${REPORT_URL:-not published}"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

# The findings themselves, inline in the summary, not only in the .report — same reason
# sast-scan learned this: a count with a download behind it is read at the next audit,
# not by the developer who opened the pull request.
SUMMARY_LIST_CAP=25

if [ "$outcome" = "findings" ]; then
    {
        echo ""
        echo "<details><summary>Findings</summary>"
        echo ""
        echo '```'
        echo "SEVERITY  PACKAGE  INSTALLED  FIXED  ADVISORY"
        { trivy_rows | sed 's/^/[trivy]  /'; osv_rows | sed 's/^/[osv]    /'; } \
            | head -n "$SUMMARY_LIST_CAP" | tr '\t' '  '
        echo '```'
        if [ "$findings" -gt "$SUMMARY_LIST_CAP" ]; then
            echo ""
            echo "Showing ${SUMMARY_LIST_CAP} of ${findings}. The full list is in the \`$(basename "$DEPS_REPORT_FILE")\` artifact."
        fi
        echo ""
        echo "</details>"
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi

# Composed here rather than in the workflow so the harness covers the wording, the same
# rule the other scanners follow. Four outcomes, and `no-manifests` is the one that must
# never read as clean: a repository with no lockfile has not been checked, it has been
# skipped, and those look identical in a bare count.
case "$outcome" in
    findings)
        emit_message "📚 Deps (Trivy fs + OSV): 🟡 ${findings} finding(s) — Trivy ${trivy_findings}, OSV ${osv_findings}"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
        ;;
    no-manifests)
        emit_message "📚 Deps (Trivy fs + OSV): ⚠️ no lockfile found — nothing was checked"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
        ;;
    *)
        emit_message "📚 Deps (Trivy fs + OSV): 🟢 clean — Trivy and OSV both parsed a lockfile and found nothing"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
        ;;
esac

emit outcome "$outcome"
emit findings "$findings"
echo "Dependency scan — Trivy: ${trivy_state} (${trivy_findings}), OSV-Scanner: ${osv_state} (${osv_findings}), outcome: ${outcome}"
