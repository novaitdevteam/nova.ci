#!/usr/bin/env bash
#
# Run Semgrep OSS over the checked-out source and turn the result into three things:
# a .report file, a job summary, and a ready-to-send notifier line.
#
# Fails closed on anything that is not a clean answer. "Semgrep found nothing" and
# "Semgrep never ran" produce identical empty result sets, so this script refuses to
# call the second one clean: the canary rule must fire and at least one file must
# have been scanned, or the outcome is `error` and the job goes red.
#
set -euo pipefail

: "${SEMGREP_IMAGE:?}" "${SEMGREP_CONFIGS:?}" "${SEMGREP_SEVERITY:?}"
: "${SEMGREP_SRC:?}" "${SEMGREP_REPORT_FILE:?}" "${SEMGREP_ACTION_ROOT:?}"

CANARY_MARKER="NOVA_CI_SEMGREP_CANARY_MARKER"
json="${RUNNER_TEMP:-/tmp}/semgrep.json"

emit() { # emit <key> <value>
    printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/null}"
}

emit_message() { # emit_message <text>
    {
        echo "message<<SEMGREP_EOF"
        printf '%s\n' "$1"
        echo "SEMGREP_EOF"
    } >> "${GITHUB_OUTPUT:-/dev/null}"
}

finish_error() { # finish_error <reason>
    local reason="$1"
    echo "::error::SAST scan could not complete: ${reason}"
    emit outcome error
    emit findings 0
    emit_message "🔍 SAST (Semgrep): ❌ scan failed — ${reason}"
    {
        echo "## 🔍 SAST (Semgrep)"
        echo ""
        echo "> [!CAUTION]"
        echo "> Scan did not complete: ${reason}. This is a broken gate, not a clean result."
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    exit 2
}

# The canary lives in a directory of its own that is scanned alongside the source, so
# a repository with zero matching files still proves the engine ran.
canary_dir="${RUNNER_TEMP:-/tmp}/semgrep-canary"
mkdir -p "$canary_dir"
printf '%s\n' "$CANARY_MARKER" > "$canary_dir/canary.txt"

config_args=()
for cfg in $SEMGREP_CONFIGS; do
    config_args+=(--config="$cfg")
done
config_args+=(--config=/canary/canary.yaml)

set +e
docker run --rm \
    -v "${SEMGREP_SRC}:/src:ro" \
    -v "${canary_dir}:/canary-src:ro" \
    -v "${SEMGREP_ACTION_ROOT}/canary.yaml:/canary/canary.yaml:ro" \
    -v "${RUNNER_TEMP:-/tmp}:/out" \
    -w /src \
    "$SEMGREP_IMAGE" \
    semgrep scan "${config_args[@]}" \
        --json --metrics=off --quiet --no-git-ignore \
        --output /out/semgrep.json \
        /src /canary-src
rc=$?
set -e

# /out is RUNNER_TEMP, so the container's output path is $json on the host. A missing
# file means the container never got far enough to write one.
[ -s "$json" ] || finish_error "Semgrep produced no output (exit ${rc})"
[ "$rc" -le 1 ] || finish_error "Semgrep exited ${rc}"
jq -e . "$json" >/dev/null 2>&1 || finish_error "Semgrep output is not valid JSON"

scanned=$(jq '.paths.scanned | length' "$json")
[ "$scanned" -gt 0 ] || finish_error "Semgrep scanned zero files"

# Semgrep puts two different kinds of problem in .errors[]: a config/rule resolution
# failure — no `path`, the error is about the run itself, e.g. a registry pack that
# could not be fetched — and a per-file problem such as a parse error or a timeout,
# which carries the `path` of the offending file. The second kind is routine on a large
# TypeScript monorepo and is not evidence the configs failed to load; novatalks.core hit
# 12 of them and none was a resolution failure. Print every one before deciding anything
# — the detail below is the ground truth a bare count never gave us, the same defect
# this repository keeps legislating against (see gitleaks git --log-opts and the ZAP
# report vs. console split). The canary and this guard only close the trap together:
# the canary proves the engine executed, this proves the configs it executed with
# actually loaded; a canary that still fires despite every registry pack failing to
# fetch is exactly the gap this guard exists to close.
err_count=$(jq '.errors | length' "$json")
if [ "$err_count" -gt 0 ]; then
    echo "Semgrep reported ${err_count} error(s):"
    jq -r '.errors[] | "  [\(.level // "?")] type=\(.type // "?") path=\(.path // "-"): \((.message // "") | .[0:200])"' "$json"
fi

config_err_count=$(jq '[.errors[] | select(.path == null or .path == "")] | length' "$json")
[ "$config_err_count" -eq 0 ] || finish_error "Semgrep reported ${config_err_count} configuration/rule error(s) — rules may not have loaded"

file_err_count=$(( err_count - config_err_count ))
[ "$file_err_count" -eq 0 ] || echo "::warning::Semgrep reported ${file_err_count} per-file error(s) (parse errors, timeouts) — configs resolved (canary fired), treating as non-blocking."

canary_hits=$(jq '[.results[] | select(.check_id | test("nova-ci-semgrep-canary"))] | length' "$json")
[ "$canary_hits" -gt 0 ] || finish_error "the canary rule did not fire — the rule engine did not run"

# The canary's severity is a fixed INFO in canary.yaml, but SEMGREP_SEVERITY is a
# caller-configurable input with no enum restriction — if it is ever set to INFO,
# the canary hit must still never be countable as a finding, so it is excluded by
# check_id here independent of severity, not just by the severity happening to differ.
findings=$(jq --arg sev "$SEMGREP_SEVERITY" \
    '[.results[] | select(.extra.severity == $sev and (.check_id | test("nova-ci-semgrep-canary") | not))] | length' "$json")

{
    echo "=============================="
    echo " SAST: Semgrep"
    echo " Image:    ${SEMGREP_IMAGE}"
    echo " Configs:  ${SEMGREP_CONFIGS}"
    echo " Severity: ${SEMGREP_SEVERITY}"
    echo "=============================="
    echo ""
    echo "=== ${SEMGREP_SEVERITY} findings: ${findings} ==="
    echo ""
    jq -r --arg sev "$SEMGREP_SEVERITY" \
        '.results[] | select(.extra.severity == $sev and (.check_id | test("nova-ci-semgrep-canary") | not))
         | "\(.path):\(.start.line)  [\(.check_id)]\n    \(.extra.message)\n"' "$json"
} > "$SEMGREP_REPORT_FILE"

if [ "$findings" -gt 0 ]; then
    outcome=findings
    echo "::warning::Semgrep found ${findings} ${SEMGREP_SEVERITY} finding(s). See ${SEMGREP_REPORT_FILE}."
    message="🔍 SAST (Semgrep): 🟡 ${findings} ${SEMGREP_SEVERITY}"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    alert=WARNING
    headline="⚠️ ${findings} ${SEMGREP_SEVERITY} finding(s) — review the report."
else
    outcome=clean
    message="🔍 SAST (Semgrep): 🟢 clean"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    alert=NOTE
    headline="✅ No ${SEMGREP_SEVERITY} findings."
fi

{
    echo "## 🔍 SAST (Semgrep)"
    echo ""
    echo "> [!${alert}]"
    echo "> ${headline}"
    echo ""
    echo "- Image: \`${SEMGREP_IMAGE}\`"
    echo "- Configs: \`${SEMGREP_CONFIGS}\`"
    echo "- Files scanned: ${scanned}"
    echo "- Report: ${REPORT_URL:-not published}"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

emit outcome "$outcome"
emit findings "$findings"
emit_message "$message"
echo "Semgrep results — ${SEMGREP_SEVERITY}: ${findings} (outcome: ${outcome})"
