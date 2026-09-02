#!/usr/bin/env bash
#
# Shared ZAP result parsing for dast/ and dast-api/. Only the logic where a divergent
# copy would silently measure nothing lives here: the tally-line anchor, tally_at, and
# the numeric guard. Report assembly and notifier text differ per scanner and stay in
# each scan.sh. Sourced, never executed.

# _zap_tally_at <tally-line> <label>
# Plain top-level helper — a function cannot be declared `local`.
_zap_tally_at() { printf '%s' "$1" | tr '\t' '\n' | sed -n "s/^$2: //p" | head -1; }

# zap_tally_parse <console-file> <error-fn>
# Reads the one tally line ZAP prints at the end of any completed scan and sets the
# globals failures/findings/infos/accepted/passes. Calls <error-fn> (the caller's
# scanner_error) on a missing or non-numeric tally — fail closed, never guess a zero.
#
# The anchor is ANSI-C quoted so the tab is a real byte. GNU grep reads a plain '\t' in
# a pattern as a literal 't' (warning: stray \ before t), so the plainly-quoted form
# matches nothing on every Linux runner and reds every completed scan; only a macOS
# harness run passes it. Anchored on the tally's shape, not the bare FAIL-NEW: prefix,
# because print_rule emits a per-rule FAIL-NEW: <alert> line before the tally.
zap_tally_parse() {
    local console="$1" err_fn="$2" tally
    tally="$(grep -m1 -E $'^FAIL-NEW: [0-9]+\tFAIL-INPROG: ' "$console" || true)"
    [ -n "$tally" ] || { "$err_fn" "ZAP printed no result tally — the scan did not complete"; return; }

    failures="$(_zap_tally_at "$tally" FAIL-NEW)"
    findings="$(_zap_tally_at "$tally" WARN-NEW)"
    infos="$(_zap_tally_at "$tally" INFO)"
    accepted="$(_zap_tally_at "$tally" IGNORE)"
    passes="$(_zap_tally_at "$tally" PASS)"

    local n
    for n in "$failures" "$findings" "$infos" "$accepted" "$passes"; do
        [[ "$n" =~ ^[0-9]+$ ]] || { "$err_fn" "ZAP tally line is malformed: ${tally}"; return; }
    done
}
